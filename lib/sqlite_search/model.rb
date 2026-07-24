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
          pk  = "#{connection.quote_table_name(table_name)}.#{connection.quote_column_name(primary_key)}"

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
        after_save_commit do
          if (saved_changes.keys & cols).any?
            SqliteSearch::Fts5::Backend.new(definition).sync(self)
          end
        end
        after_destroy_commit do
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

          vector = definition.embed(query.to_s, record_model: self)
          hits = definition.neighbor_model
            .nearest_neighbors(:embedding, vector, distance: definition.distance)
            .limit(k)
            .map { |r| [r.id, 1.0 - r.neighbor_distance] }
          hits = hits.select { |(_, sim)| sim >= threshold } if threshold
          next none if hits.empty?

          ids = hits.map(&:first)
          sims = hits.to_h
          pk = connection.quote_column_name(primary_key)
          order = Arel.sql("CASE #{quoted_table_name}.#{pk} " +
            ids.each_with_index.map { |id, i| "WHEN #{connection.quote(id)} THEN #{i}" }.join(" ") + " END")

          decorate = Module.new do
            define_method(:records) do
              super().each { |rec| rec.define_singleton_method(definition.similarity_method) { sims[rec.id] } }
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
    end
  end
end
