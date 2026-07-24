# frozen_string_literal: true

require "test_helper"

class SyncTest < SqliteSearch::TestCase
  def setup
    @conn = ActiveRecord::Base.connection
    @conn.create_table(:posts, force: true) { |t|
      t.string :title
      t.text :body
    }
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

  def test_blanking_indexed_field_removes_from_index
    p = @klass.create!(body: "morning coffee")
    assert_equal 1, indexed_count("coffee")
    p.update!(body: "")
    assert_equal 0, indexed_count("coffee")
  end

  def test_multi_column_partial_nil_indexes_present_columns
    conn = ActiveRecord::Base.connection
    conn.create_table(:articles, force: true) { |t|
      t.string :title
      t.text :body
    }
    conn.create_virtual_table("articles_full_fts", :fts5, ["title", "body", "tokenize = 'porter unicode61'"])
    klass = Class.new(ActiveRecord::Base) do
      self.table_name = "articles"
      include SqliteSearch::Model

      fts5_scope :full, against: {title: 2.0, body: 1.0}
    end
    klass.create!(title: "coffee guide", body: nil)
    count = conn.select_value("SELECT count(*) FROM articles_full_fts WHERE articles_full_fts MATCH 'coffee'")
    assert_equal 1, count
  ensure
    conn = ActiveRecord::Base.connection
    %w[articles_full_fts articles].each { |t| conn.execute("DROP TABLE IF EXISTS #{conn.quote_table_name(t)}") }
  end

  def test_non_integer_primary_key_raises_clear_error
    conn = ActiveRecord::Base.connection
    conn.create_table(:docs, id: false, force: true) { |t|
      t.string :uid, primary_key: true
      t.text :body
    }
    conn.create_virtual_table("docs_by_body_fts", :fts5, ["body", "tokenize = 'porter unicode61'"])
    klass = Class.new(ActiveRecord::Base) do
      self.table_name = "docs"
      self.primary_key = "uid"
      include SqliteSearch::Model

      fts5_scope :by_body, against: :body
    end
    error = assert_raises(SqliteSearch::Error) { klass.create!(uid: "abc", body: "coffee") }
    assert_match(/integer primary key/, error.message)
    assert_equal 0, klass.count # the guard raised in-transaction, so the row rolled back
  ensure
    conn = ActiveRecord::Base.connection
    %w[docs_by_body_fts docs].each { |t| conn.execute("DROP TABLE IF EXISTS #{conn.quote_table_name(t)}") }
  end

  def test_fts_sync_is_atomic_with_the_row
    # No FTS table exists for this scope, so the in-transaction sync write fails.
    @conn.create_table(:notes, force: true) { |t| t.text :body }
    klass = Class.new(ActiveRecord::Base) do
      self.table_name = "notes"
      include SqliteSearch::Model

      fts5_scope :body_search, against: :body
    end
    assert_raises(ActiveRecord::StatementInvalid) { klass.create!(body: "coffee") }
    assert_equal 0, klass.count # row rolled back with the failed index write
  ensure
    @conn.execute("DROP TABLE IF EXISTS notes")
  end
end
