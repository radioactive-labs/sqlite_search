# frozen_string_literal: true

require "sqlite_search/fts5"

module SqliteSearch
  module Fts5
    # Immutable per-scope configuration.
    class Definition
      attr_reader :model, :name, :columns, :weights, :tokenizer, :table_name

      def initialize(model:, name:, against:, tokenizer:)
        @model = model
        @name = name.to_sym
        @columns = SqliteSearch::Fts5.columns_for(against)
        @weights = SqliteSearch::Fts5.weights_for(against)
        @tokenizer = tokenizer
        @table_name = "#{model.table_name}_#{@name}_fts"
      end

      def column_names = columns.map(&:to_s)
    end
  end
end
