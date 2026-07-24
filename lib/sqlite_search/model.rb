# frozen_string_literal: true

require "active_support/concern"
require "sqlite_search/fts5/definition"

module SqliteSearch
  module Model
    extend ActiveSupport::Concern

    class_methods do
      def sqlite_search_fts5_definitions
        @sqlite_search_fts5_definitions ||= {}
      end

      def fts5_scope(name, against:, tokenizer: "porter unicode61")
        definition = Fts5::Definition.new(model: self, name: name, against: against, tokenizer: tokenizer)
        sqlite_search_fts5_definitions[definition.name] = definition

        scope name, ->(query, prefix: false, raw: nil) do
          match = raw || SqliteSearch::Query.build(query, prefix: prefix)
          next none if match.nil? || match.empty?

          fts = connection.quote_table_name(definition.table_name)
          pk = "#{connection.quote_table_name(table_name)}.#{connection.quote_column_name(primary_key)}"
          where("#{pk} IN (SELECT rowid FROM #{fts} WHERE #{fts} MATCH ?)", match)
        end
      end
    end
  end
end
