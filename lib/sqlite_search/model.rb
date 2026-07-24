# frozen_string_literal: true

require "active_support/concern"
require "sqlite_search/fts5/definition"

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
    end
  end
end
