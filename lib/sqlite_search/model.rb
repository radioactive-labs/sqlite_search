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

      def fts5_scope(name, against:, source: nil, watch: nil)
        if source && watch.nil?
          raise SqliteSearch::Error, "fts5_scope :#{name} uses source:, so it needs watch: (the attributes that change the text)."
        end
        definition = Fts5::Definition.new(model: self, name: name, against: against, source: source, watch: watch)
        (@sqlite_search_fts5_definitions ||= {})[definition.name] = definition

        scope name, ->(query = nil, prefix: false, raw: nil) do
          match = raw || SqliteSearch::Query.build(query, prefix: prefix)
          next none.extending(SqliteSearch::Fts5::NullRank) if match.nil? || match.to_s.empty?

          fts, pk = with_connection do |conn|
            [conn.quote_table_name(definition.table_name), "#{quoted_table_name}.#{conn.quote_column_name(primary_key)}"]
          end

          # bm25() is only valid in a query that MATCHes the fts table, so
          # order_by_rank joins the fts table and re-applies MATCH here. It
          # reorders: relevance replaces any order chained before the search.
          rank_module = Module.new do
            define_method(:order_by_rank) do |threshold: nil|
              bm25 = with_connection { |conn| definition.bm25_expression(conn) }
              ranked = joins("JOIN #{fts} ON #{fts}.rowid = #{pk}").where("#{fts} MATCH ?", match)
              ranked = ranked.where("-#{bm25} >= ?", threshold) if threshold
              ranked
                .select("#{quoted_table_name}.*, -#{bm25} AS #{definition.rank_column}")
                .reorder(Arel.sql(bm25))
                .extending(SqliteSearch::ScoredRelation)
            end
          end

          where("#{pk} IN (SELECT rowid FROM #{fts} WHERE #{fts} MATCH ?)", match).extending(rank_module)
        end

        cols = definition.watch_names
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
        definitions.each { |definition| SqliteSearch::Fts5::Backend.new(definition).rebuild }
      end

      def sqlite_search_vec_definitions
        own = (@sqlite_search_vec_definitions ||= {})
        return own unless superclass.respond_to?(:sqlite_search_vec_definitions)
        superclass.sqlite_search_vec_definitions.merge(own)
      end

      # sync: :async (enqueue EmbedJob on save), :inline (embed in the save
      # callback), or :manual (never on save; call record.reembed yourself).
      def vec_scope(name, dimensions:, against: nil, source: nil, watch: nil, distance: :cosine, embedder: nil, sync: :async)
        unless SqliteSearch::Vec::SYNC_MODES.include?(sync)
          raise SqliteSearch::Error, "Unsupported sync #{sync.inspect}. Use one of: #{SqliteSearch::Vec::SYNC_MODES.join(", ")}."
        end
        if source && watch.nil? && sync != :manual
          raise SqliteSearch::Error, "vec_scope :#{name} uses source:, so it needs watch: (the attributes that change the text)."
        end
        SqliteSearch::Vec.load!
        definition = SqliteSearch::Vec::Definition.new(
          model: self, name: name, against: against, source: source, watch: watch,
          dimensions: dimensions, distance: distance, embedder: embedder
        )
        (@sqlite_search_vec_definitions ||= {})[definition.name] = definition

        scope name, ->(query = nil, k: 20, threshold: nil) do
          next none if query.nil? || query.to_s.strip.empty?

          vector = definition.embed(query.to_s, record_model: klass)

          caller_conditions = all.only(:where, :joins)
          src = quoted_table_name
          vec, pkc = with_connection do |conn|
            [conn.quote_table_name(definition.table_name), conn.quote_column_name(primary_key)]
          end

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
          pk_sql = "#{src}.#{pkc}"
          # Order and per-row scores are computed in Ruby (from the KNN), so carry
          # them as selected CASE columns: <name>_distance is then a real attribute.
          # Nearness replaces any order chained before the search.
          order, cols = with_connection do |conn|
            cols = ["#{src}.*", "#{SqliteSearch::Sql.id_case(pk_sql, distances, conn)} AS #{definition.distance_method}"]
            if definition.cosine?
              cols << "#{SqliteSearch::Sql.id_case(pk_sql, distances.transform_values { |d| 1.0 - d }, conn)} AS #{definition.similarity_method}"
            end
            [Arel.sql(SqliteSearch::Sql.id_case(pk_sql, ids.each_with_index.to_h, conn)), cols]
          end
          where(primary_key => ids).reorder(order).select(cols.join(", ")).extending(SqliteSearch::ScoredRelation)
        end

        vec_cols = definition.watch_names
        vec_sync = sync
        SqliteSearch.ensure_embed_job! if vec_sync == :async
        unless vec_sync == :manual
          # saved_changes in an after_commit callback only reflects the last save
          # of the transaction, so note a watched change on each save and act on
          # it at commit.
          after_save do
            (@sqlite_search_pending_embeds ||= Set.new) << definition.name if (saved_changes.keys & vec_cols).any?
          end
          after_rollback { @sqlite_search_pending_embeds = nil }
          after_save_commit do
            if @sqlite_search_pending_embeds&.delete?(definition.name)
              if vec_sync == :inline
                SqliteSearch::Vec::Backend.new(definition).embed_and_store(self)
              else
                SqliteSearch::EmbedJob.perform_later(self.class.name, public_send(self.class.primary_key), definition.name.to_s)
              end
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

        scope name, ->(query = nil, limit: 20, rerank: true, fts5_threshold: nil, vec_threshold: nil) do
          next none if query.nil? || query.to_s.strip.empty?
          # candidate pool per arm before fusion; capped so a large limit: can't over-fetch
          pool = [limit * 3, 100].min

          fts_ids = all.public_send(fts5_name, query).order_by_rank(threshold: fts5_threshold).limit(pool).pluck(primary_key)
          vec_ids = all.public_send(vec_name, query, k: pool, threshold: vec_threshold).pluck(primary_key)

          fused = SqliteSearch::Hybrid.rrf(fts_ids, vec_ids, k: rrf_k)
          next none if fused.empty?

          reranker = rerank ? SqliteSearch.config.reranker : nil
          fused = SqliteSearch::Hybrid.rerank(query, fused, model: klass, scope_name: name.to_sym, reranker: reranker)
          next none if fused.empty?
          fused = fused.first(limit)
          ids = fused.map(&:first)
          scores = fused.to_h
          # Fused rank and score come from Ruby, so carry them as SQL: the score
          # becomes a real <name>_score attribute (works with pluck, first, etc.).
          # The fused order replaces any order chained before the search.
          order, score_col = with_connection do |conn|
            pk_sql = "#{quoted_table_name}.#{conn.quote_column_name(primary_key)}"
            [
              Arel.sql(SqliteSearch::Sql.id_case(pk_sql, ids.each_with_index.to_h, conn)),
              "#{SqliteSearch::Sql.id_case(pk_sql, scores, conn)} AS #{score_method}"
            ]
          end
          where(primary_key => ids).reorder(order).select("#{quoted_table_name}.*, #{score_col}")
            .extending(SqliteSearch::ScoredRelation)
        end
      end
    end

    # Embed this record into one vec index (or every one) now. This is how a
    # sync: :manual scope is kept current, typically from the app's own job.
    def reembed(name = nil)
      definitions = self.class.sqlite_search_vec_definitions
      selected = name ? [definitions.fetch(name.to_sym)] : definitions.values
      selected.each { |definition| SqliteSearch::Vec::Backend.new(definition).embed_and_store(self) }
    end
  end
end
