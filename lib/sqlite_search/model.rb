# frozen_string_literal: true

require "active_support/concern"
require "sqlite_search/fts5/definition"
require "sqlite_search/vec/definition"

module SqliteSearch
  module Model
    extend ActiveSupport::Concern

    class_methods do
      def sqlite_search_fts5_definitions
        own = (@sqlite_search_fts5_definitions ||= {})
        return own unless superclass.respond_to?(:sqlite_search_fts5_definitions)
        superclass.sqlite_search_fts5_definitions.merge(own)
      end

      def fts5_scope(name, against:, tokenizer: "porter unicode61")
        definition = Fts5::Definition.new(model: self, name: name, against: against, tokenizer: tokenizer)
        (@sqlite_search_fts5_definitions ||= {})[definition.name] = definition

        scope name, ->(query = nil, prefix: false, raw: nil) do
          match = raw || SqliteSearch::Query.build(query, prefix: prefix)
          next none.extending(SqliteSearch::Fts5::NullRank) if match.nil? || match.to_s.empty?

          fts = connection.quote_table_name(definition.table_name)
          pk = "#{connection.quote_table_name(table_name)}.#{connection.quote_column_name(primary_key)}"

          # bm25() is only valid in a query that MATCHes the fts table, so
          # order_by_rank joins the fts table and re-applies MATCH here.
          rank_module = Module.new do
            define_method(:order_by_rank) do
              bm25 = definition.bm25_expression(connection)
              joins("JOIN #{fts} ON #{fts}.rowid = #{pk}")
                .where("#{fts} MATCH ?", match)
                .select("#{connection.quote_table_name(table_name)}.*, -#{bm25} AS #{definition.rank_column}")
                .order(Arel.sql(bm25))
            end
          end

          where("#{pk} IN (SELECT rowid FROM #{fts} WHERE #{fts} MATCH ?)", match).extending(rank_module)
        end

        cols = definition.column_names
        # FTS5 sync runs inside the transaction (after_save/after_destroy), not
        # after_commit: an FTS5 write is a cheap local write, so keeping it in the
        # transaction makes the index atomic with the row. A failed write rolls
        # both back rather than leaving a committed row with a stale index.
        after_save do
          if (saved_changes.keys & cols).any?
            SqliteSearch::Fts5::Backend.new(definition).sync(self)
          end
        end
        after_destroy do
          SqliteSearch::Fts5::Backend.new(definition).remove(self)
        end
      end

      def reindex(name = nil)
        definitions = name ? [sqlite_search_fts5_definitions.fetch(name.to_sym)] : sqlite_search_fts5_definitions.values
        definitions.each { |definition| SqliteSearch::Fts5::Backend.new(definition).rebuild(self) }
      end

      def sqlite_search_vec_definitions
        own = (@sqlite_search_vec_definitions ||= {})
        return own unless superclass.respond_to?(:sqlite_search_vec_definitions)
        superclass.sqlite_search_vec_definitions.merge(own)
      end

      def vec_scope(name, against:, dimensions:, distance: :cosine, embedder: nil, sync: :async)
        SqliteSearch::Vec.load!
        definition = SqliteSearch::Vec::Definition.new(
          model: self, name: name, against: against, dimensions: dimensions, distance: distance, embedder: embedder
        )
        (@sqlite_search_vec_definitions ||= {})[definition.name] = definition

        scope name, ->(query = nil, k: 20, threshold: nil) do
          next none if query.nil? || query.to_s.strip.empty?

          vector = definition.embed(query.to_s, record_model: klass)

          caller_conditions = all.only(:where, :joins)
          src = connection.quote_table_name(table_name)
          vec = connection.quote_table_name(definition.table_name)
          pkc = connection.quote_column_name(primary_key)

          knn = definition.neighbor_model
            .joins("JOIN #{src} ON #{src}.#{pkc} = #{vec}.id")
            .merge(caller_conditions)
            .nearest_neighbors(:embedding, vector, distance: definition.distance)
            .limit(k)
          hits = knn.map { |r| [r.id, r.neighbor_distance] }
          if threshold
            hits = if definition.cosine?
              hits.select { |(_, dist)| (1.0 - dist) >= threshold } # threshold = minimum cosine similarity
            else
              hits.select { |(_, dist)| dist <= threshold }         # threshold = maximum distance
            end
          end
          next none if hits.empty?

          ids = hits.map(&:first)
          distances = hits.to_h
          order = Arel.sql("CASE #{quoted_table_name}.#{pkc} " +
            ids.each_with_index.map { |id, i| "WHEN #{connection.quote(id)} THEN #{i}" }.join(" ") + " END")
          decorate = Module.new do
            define_method(:records) do
              super().each do |rec|
                d = distances[rec.id]
                rec.define_singleton_method(definition.distance_method) { d }
                rec.define_singleton_method(definition.similarity_method) { 1.0 - d } if definition.cosine?
              end
            end
          end
          where(primary_key => ids).order(order).extending(decorate)
        end

        vec_cols = definition.column_names
        vec_sync = sync
        SqliteSearch.ensure_embed_job! unless vec_sync == :inline
        after_save_commit do
          if (saved_changes.keys & vec_cols).any?
            backend = SqliteSearch::Vec::Backend.new(definition)
            if vec_sync == :inline
              backend.embed_and_store(self)
            else
              SqliteSearch::EmbedJob.perform_later(self.class.name, public_send(self.class.primary_key), definition.name.to_s)
            end
          end
        end
        after_destroy_commit do
          SqliteSearch::Vec::Backend.new(definition).remove(self)
        end
      end

      def reembed(name = nil)
        definitions = name ? [sqlite_search_vec_definitions.fetch(name.to_sym)] : sqlite_search_vec_definitions.values
        definitions.each { |definition| SqliteSearch::Vec::Backend.new(definition).reembed(self) }
      end

      def sqlite_search_hybrid_definitions
        own = (@sqlite_search_hybrid_definitions ||= {})
        return own unless superclass.respond_to?(:sqlite_search_hybrid_definitions)
        superclass.sqlite_search_hybrid_definitions.merge(own)
      end

      def hybrid_scope(name, fts5:, vec:, k: 60)
        fts5_name = fts5.to_sym
        vec_name = vec.to_sym
        if name.to_sym == fts5_name || name.to_sym == vec_name
          raise SqliteSearch::Error, "hybrid_scope :#{name} must not reuse its own fts5:/vec: scope name (it would overwrite that scope)."
        end
        unless sqlite_search_fts5_definitions.key?(fts5_name)
          raise SqliteSearch::Error, "hybrid_scope :#{name} references fts5: :#{fts5_name}, but no such fts5_scope is declared on #{self.name}."
        end
        unless sqlite_search_vec_definitions.key?(vec_name)
          raise SqliteSearch::Error, "hybrid_scope :#{name} references vec: :#{vec_name}, but no such vec_scope is declared on #{self.name}."
        end
        (@sqlite_search_hybrid_definitions ||= {})[name.to_sym] = {fts5: fts5_name, vec: vec_name, k: k}
        rrf_k = k
        score_method = "#{name}_score"

        scope name, ->(query = nil, limit: 20, rerank: true) do
          next none if query.nil? || query.to_s.strip.empty?
          # candidate pool per arm before fusion; capped so a large limit: can't over-fetch
          pool = [limit * 3, 100].min

          fts_ids = all.public_send(fts5_name, query).order_by_rank.limit(pool).pluck(primary_key)
          vec_ids = all.public_send(vec_name, query, k: pool).pluck(primary_key)

          fused = SqliteSearch::Hybrid.rrf(fts_ids, vec_ids, k: rrf_k)
          next none if fused.empty?

          reranker = rerank ? SqliteSearch.config.reranker : nil
          fused = SqliteSearch::Hybrid.rerank(query, fused, model: klass, scope_name: name.to_sym, reranker: reranker)
          next none if fused.empty?
          fused = fused.first(limit)
          ids = fused.map(&:first)
          scores = fused.to_h
          pkc = connection.quote_column_name(primary_key)
          order = Arel.sql("CASE #{quoted_table_name}.#{pkc} " +
            ids.each_with_index.map { |id, i| "WHEN #{connection.quote(id)} THEN #{i}" }.join(" ") + " END")
          decorate = Module.new do
            define_method(:records) do
              super().each { |rec| rec.define_singleton_method(score_method) { scores[rec.id] } }
            end
          end
          where(primary_key => ids).order(order).extending(decorate)
        end
      end
    end
  end
end
