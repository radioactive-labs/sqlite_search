# frozen_string_literal: true

require "minitest/autorun"
require "active_record"
require "sqlite_search"

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")

module SqliteSearch
  class TestCase < Minitest::Test
  end
end
