# frozen_string_literal: true

module SqliteSearch
  module Fts5
    # Writes to the FTS5 virtual table for one definition. Model-owned sync:
    # upsert-by-rowid on save, delete on destroy, full rebuild on demand.
    class Backend
      def initialize(definition)
        @definition = definition
      end

      def sync(record)
        record.class.with_connection do |conn|
          id = record.public_send(record.class.primary_key)
          unless id.is_a?(Integer)
            raise SqliteSearch::Error,
              "sqlite_search FTS5 indexing requires an integer primary key (used as the FTS rowid), " \
              "but #{record.class.name}##{record.class.primary_key} is #{id.class} (#{id.inspect}). " \
              "FTS5 does not support non-integer rowids."
          end
          conn.transaction do
            delete_row(conn, id)
            values = @definition.columns.map { |c| record.public_send(c) }
            insert_row(conn, id, values) unless values.all? { |v| v.nil? || v.to_s.empty? }
          end
        end
      end

      def remove(record)
        record.class.with_connection do |conn|
          delete_row(conn, record.public_send(record.class.primary_key))
        end
      end

      def rebuild(model)
        model.with_connection do |conn|
          conn.execute("DELETE FROM #{quoted(conn)}")
          col_list = @definition.columns.map { |c| conn.quote_column_name(c) }.join(", ")
          non_blank = @definition.columns.map { |c| "COALESCE(#{conn.quote_column_name(c)}, '')" }.join(" || ")
          conn.execute(<<~SQL.squish)
            INSERT INTO #{quoted(conn)} (rowid, #{col_list})
            SELECT #{conn.quote_column_name(model.primary_key)}, #{col_list}
            FROM #{conn.quote_table_name(model.table_name)}
            WHERE (#{non_blank}) <> ''
          SQL
        end
      end

      private

      def quoted(conn) = conn.quote_table_name(@definition.table_name)

      def delete_row(conn, id)
        conn.execute("DELETE FROM #{quoted(conn)} WHERE rowid = #{conn.quote(id)}")
      end

      def insert_row(conn, id, values)
        col_list = @definition.columns.map { |c| conn.quote_column_name(c) }.join(", ")
        vals = ([id] + values).map { |v| conn.quote(v) }.join(", ")
        conn.execute("INSERT INTO #{quoted(conn)} (rowid, #{col_list}) VALUES (#{vals})")
      end
    end
  end
end
