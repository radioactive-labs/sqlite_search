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
      # ascending, and expose -bm25 as the rank so higher = better. weights:
      # (from order_by_rank) replaces the against: weights for one query.
      def bm25_expression(connection, weights: nil)
        args = [connection.quote_table_name(table_name)]
        column_weights = if weights
          query_weights(connection, weights)
        elsif self.weights
          table_weights(connection)
        end
        args.concat(column_weights.map { |w| format("%g", w) }) if column_weights
        "bm25(#{args.join(", ")})"
      end

      # Per-query weights keyed by FTS column, lined up by table position.
      # Columns left out weigh 0, so they stop contributing to the rank.
      def query_weights(connection, weights)
        by_column = weights.to_h { |column, weight| [column.to_s, Float(weight)] }
        unknown = by_column.keys - column_names
        if unknown.any?
          raise SqliteSearch::Error, "fts5_scope :#{name} has no column(s) #{unknown.join(", ")} to weight; its columns are #{column_names.join(", ")}."
        end
        if by_column.values.any? { |weight| !weight.finite? || weight.negative? }
          raise SqliteSearch::Error, "fts5_scope :#{name} weights must be finite and non-negative, got #{weights.inspect}."
        end
        connection.columns(table_name).map { |c| by_column.fetch(c.name, 0.0) }
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
