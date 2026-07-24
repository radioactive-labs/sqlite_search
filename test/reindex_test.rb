# frozen_string_literal: true
require "test_helper"

class ReindexTest < SqliteSearch::TestCase
  def setup
    @conn = ActiveRecord::Base.connection
    @conn.create_table(:posts, force: true) { |t| t.text :body }
    @conn.create_virtual_table("posts_by_body_fts", :fts5, ["body", "tokenize = 'porter unicode61'"])
    @klass = Class.new(ActiveRecord::Base) do
      self.table_name = "posts"
      include SqliteSearch::Model
      fts5_scope :by_body, against: :body
    end
  end

  def teardown
    %w[posts_by_body_fts posts].each { |t| @conn.execute("DROP TABLE IF EXISTS #{@conn.quote_table_name(t)}") }
  end

  def test_reindex_recovers_bulk_inserts
    @klass.insert_all([{ id: 1, body: "morning coffee" }, { id: 2, body: "evening tea" }])
    assert_equal [], @klass.by_body("coffee").pluck(:id) # callbacks bypassed

    @klass.reindex(:by_body)
    assert_equal [1], @klass.by_body("coffee").pluck(:id)
  end

  def test_reindex_all_scopes
    @klass.insert_all([{ id: 1, body: "coffee" }])
    @klass.reindex
    assert_equal [1], @klass.by_body("coffee").pluck(:id)
  end
end
