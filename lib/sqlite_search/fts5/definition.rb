# frozen_string_literal: true

require "sqlite_search/fts5"

module SqliteSearch
  module Fts5
    # Immutable per-scope configuration.
    class Definition
      attr_reader :model, :name, :columns, :weights, :table_name

      def initialize(model:, name:, against:)
        @model = model
        @name = name.to_sym
        @columns = SqliteSearch::Fts5.columns_for(against)
        @weights = SqliteSearch::Fts5.weights_for(against)
        @table_name = "#{model.table_name}_#{@name}_fts"
      end

      def column_names = columns.map(&:to_s)

      # SQLite bm25() returns lower (more negative) = better. We ORDER BY it
      # ascending, and expose -bm25 as the rank so higher = better.
      def bm25_expression(connection)
        args = [connection.quote_table_name(table_name)]
        args.concat(table_weights(connection).map { |w| format("%g", w) }) if weights
        "bm25(#{args.join(", ")})"
      end

      # bm25() takes weights by the FTS table's column position, which need not
      # match the order of the against: hash, so line them up by column name.
      def table_weights(connection)
        @table_weights ||= begin
          by_column = column_names.zip(weights).to_h
          connection.columns(table_name).map { |c| by_column.fetch(c.name, 1.0) }
        end
      end

      def rank_column = "#{name}_rank"
    end
  end
end
