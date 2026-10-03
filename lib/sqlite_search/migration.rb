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
      missing = columns.map(&:to_s) - connection.columns(table).map(&:name)
      if missing.any?
        raise SqliteSearch::Error,
          "create_fts5_index backfill: copies columns straight from #{table}, which has no #{missing.join(", ")}. " \
          "For an index built with source:, drop backfill: and run Model.reindex after migrating."
      end
      connection.execute(SqliteSearch::Fts5.copy_sql(connection, fts_table: fts_table, source_table: table,
        primary_key: primary_key, columns: columns))
    end
  end
end
