# frozen_string_literal: true

module SqliteSearch
  module Fts5
    module_function

    # against: :body | [:title, :body] | { title: 2.0, body: 1.0 }
    def columns_for(against)
      case against
      when Hash then against.keys.map(&:to_sym)
      when Array then against.map(&:to_sym)
      else [against.to_sym]
      end
    end

    def weights_for(against)
      against.is_a?(Hash) ? against.values.map(&:to_f) : nil
    end

    # INSERT ... SELECT that copies source-table columns into an FTS table,
    # keyed by primary key and skipping rows with no text at all.
    def copy_sql(conn, fts_table:, source_table:, primary_key:, columns:)
      col_list = columns.map { |c| conn.quote_column_name(c) }.join(", ")
      non_blank = columns.map { |c| "COALESCE(#{conn.quote_column_name(c)}, '')" }.join(" || ")
      <<~SQL.squish
        INSERT INTO #{conn.quote_table_name(fts_table)} (rowid, #{col_list})
        SELECT #{conn.quote_column_name(primary_key)}, #{col_list}
        FROM #{conn.quote_table_name(source_table)}
        WHERE (#{non_blank}) <> ''
      SQL
    end

    # Extended onto the .none relation returned for blank queries so that
    # .order_by_rank chains safely (returns the same empty relation).
    module NullRank
      def order_by_rank(threshold: nil) = self
    end
  end
end
