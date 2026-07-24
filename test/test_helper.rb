# frozen_string_literal: true

require "minitest/autorun"
require "active_record"
require "sqlite_search"

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")

require "neighbor"
require "sqlite_vec"
Neighbor::SQLite.initialize!

# Deterministic 3-dim stub embedder for tests (no real model).
SqliteSearch.embedder do |text, model:, scope:|
  t = text.to_s.downcase
  [
    t.include?("coffee") ? 1.0 : 0.0,
    t.include?("tea") ? 1.0 : 0.0,
    t.length.to_f / 100.0
  ]
end

module SqliteSearch
  class TestCase < Minitest::Test
  end
end
