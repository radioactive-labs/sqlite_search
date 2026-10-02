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
            insert_record(conn, id, record)
          end
        end
      end

      def remove(record)
        record.class.with_connection do |conn|
          delete_row(conn, record.public_send(record.class.primary_key))
        end
      end

      def rebuild(model)
        pk_type = model.columns_hash[model.primary_key.to_s]&.type
        unless pk_type == :integer
          raise SqliteSearch::Error,
            "sqlite_search FTS5 indexing requires an integer primary key (used as the FTS rowid), " \
            "but #{model.name}##{model.primary_key} is #{pk_type.inspect}. FTS5 does not support non-integer rowids."
        end

        model.with_connection do |conn|
          # One transaction, so readers never see an empty index and a failed
          # insert leaves the old index in place.
          conn.transaction do
            conn.execute("DELETE FROM #{quoted(conn)}")
            if @definition.source
              # Derived text only exists in Ruby, so rebuild record by record.
              model.unscoped.find_each { |record| insert_record(conn, record.public_send(model.primary_key), record) }
            else
              copy_columns(conn, model)
            end
          end
        end
      end

      private

      def quoted(conn) = conn.quote_table_name(@definition.table_name)

      def delete_row(conn, id)
        conn.execute("DELETE FROM #{quoted(conn)} WHERE rowid = #{conn.quote(id)}")
      end

      def insert_record(conn, id, record)
        values = @definition.values_for(record)
        insert_row(conn, id, values) unless values.all? { |v| v.nil? || v.to_s.empty? }
      end

      def copy_columns(conn, model)
        col_list = @definition.columns.map { |c| conn.quote_column_name(c) }.join(", ")
        non_blank = @definition.columns.map { |c| "COALESCE(#{conn.quote_column_name(c)}, '')" }.join(" || ")
        conn.execute(<<~SQL.squish)
          INSERT INTO #{quoted(conn)} (rowid, #{col_list})
          SELECT #{conn.quote_column_name(model.primary_key)}, #{col_list}
          FROM #{conn.quote_table_name(model.table_name)}
          WHERE (#{non_blank}) <> ''
        SQL
      end

      def insert_row(conn, id, values)
        col_list = @definition.columns.map { |c| conn.quote_column_name(c) }.join(", ")
        vals = ([id] + values).map { |v| conn.quote(v) }.join(", ")
        conn.execute("INSERT INTO #{quoted(conn)} (rowid, #{col_list}) VALUES (#{vals})")
      end
    end
  end
end
