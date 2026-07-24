# frozen_string_literal: true
require "test_helper"

class SyncTest < SqliteSearch::TestCase
  def setup
    @conn = ActiveRecord::Base.connection
    @conn.create_table(:posts, force: true) { |t| t.string :title; t.text :body }
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

  def indexed_count(match) = @conn.select_value("SELECT count(*) FROM posts_by_body_fts WHERE posts_by_body_fts MATCH '#{match}'")

  def test_create_indexes
    @klass.create!(body: "morning coffee")
    assert_equal 1, indexed_count("coffee")
  end

  def test_update_reindexes
    p = @klass.create!(body: "morning coffee")
    p.update!(body: "evening tea")
    assert_equal 0, indexed_count("coffee")
    assert_equal 1, indexed_count("tea")
  end

  def test_destroy_removes
    p = @klass.create!(body: "morning coffee")
    p.destroy!
    assert_equal 0, indexed_count("coffee")
  end

  def test_non_indexed_column_change_is_ignored
    p = @klass.create!(body: "morning coffee")
    p.update!(title: "changed") # title not indexed
    assert_equal 1, indexed_count("coffee") # still exactly one indexed row
  end
end
