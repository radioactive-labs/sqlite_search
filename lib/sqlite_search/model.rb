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
          next none if match.nil? || match.to_s.empty?

          fts = connection.quote_table_name(definition.table_name)
          pk = "#{connection.quote_table_name(table_name)}.#{connection.quote_column_name(primary_key)}"
          where("#{pk} IN (SELECT rowid FROM #{fts} WHERE #{fts} MATCH ?)", match)
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
    end
  end
end
