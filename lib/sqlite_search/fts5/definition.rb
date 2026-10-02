# frozen_string_literal: true

require "sqlite_search/fts5"

module SqliteSearch
  module Fts5
    # Immutable per-scope configuration.
    class Definition
      attr_reader :model, :name, :columns, :weights, :source, :table_name

      # against: names the FTS columns (and their weights). By default each
      # column's text is the record attribute of the same name. source: names
      # a method returning {column => text} instead, for text derived in Ruby.
      # watch: lists the attributes whose change triggers a resync (default:
      # the against: columns).
      def initialize(model:, name:, against:, source: nil, watch: nil)
        @model = model
        @name = name.to_sym
        @columns = SqliteSearch::Fts5.columns_for(against)
        @weights = SqliteSearch::Fts5.weights_for(against)
        @source = source
        @watch = watch
        @table_name = "#{model.table_name}_#{@name}_fts"
      end

      def column_names = columns.map(&:to_s)
      def watch_names = (@watch || columns).map(&:to_s)

      # The text to index for a record, one value per column, in column order.
      def values_for(record)
        return columns.map { |c| record.public_send(c) } unless source
        document = record.public_send(source)
        columns.map { |c| document.fetch(c) }
      end

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
