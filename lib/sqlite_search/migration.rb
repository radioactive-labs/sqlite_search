# frozen_string_literal: true

require "sqlite_search/fts5"
require "sqlite_search/vec"

module SqliteSearch
  # Mixed into ActiveRecord::Migration. Wraps create_virtual_table so the FTS5
  # table is representable in schema.rb (unlike triggers), and optionally seeds
  # it from the source table.
  module Migration
    def create_fts5_index(table, name, against:, tokenizer: "porter unicode61", primary_key: "id", backfill: false)
      columns = SqliteSearch::Fts5.columns_for(against)
      fts_table = "#{table}_#{name}_fts"

      options = columns.map(&:to_s)
      options << "tokenize = '#{tokenizer}'"
      connection.create_virtual_table(fts_table, :fts5, options)

      return unless backfill
      # Seeding only applies going up; dropping the table undoes it.
      reversible { |dir| dir.up { backfill_fts5_index(table, fts_table, columns, primary_key) } }
    end

    # vec0 indexes are keyed by an integer `id` column holding the source row's
    # primary-key value. distance: sets the vec0 distance_metric (:cosine,
    # :euclidean, or :taxicab) and must match the vec_scope's distance.
    def create_vec_index(table, name, dimensions:, distance: :cosine)
      vec_table = "#{table}_#{name}_vec"
      connection.create_virtual_table(vec_table, :vec0, [
        "id integer primary key",
        "embedding float[#{dimensions}] distance_metric=#{SqliteSearch::Vec.vec0_metric(distance)}"
      ])
    end

    private

    def backfill_fts5_index(table, fts_table, columns, primary_key)
      col_list = columns.map { |c| connection.quote_column_name(c) }.join(", ")
      non_blank = columns.map { |c| "COALESCE(#{connection.quote_column_name(c)}, '')" }.join(" || ")
      connection.execute(<<~SQL.squish)
        INSERT INTO #{connection.quote_table_name(fts_table)} (rowid, #{col_list})
        SELECT #{connection.quote_column_name(primary_key)}, #{col_list}
        FROM #{connection.quote_table_name(table)}
        WHERE (#{non_blank}) <> ''
      SQL
    end
  end
end
