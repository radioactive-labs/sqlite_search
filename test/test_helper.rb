# frozen_string_literal: true

require "minitest/autorun"
require "active_record"
require "sqlite_search"

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")

module SqliteSearch
  class TestCase < Minitest::Test
    def with_schema
      yield
    ensure
      conn = ActiveRecord::Base.connection
      conn.tables.grep(/\A(posts|posts_.*_fts)\z/).each { |t| conn.execute("DROP TABLE IF EXISTS #{conn.quote_table_name(t)}") }
    end
  end
end
