# frozen_string_literal: true

require "test_helper"
require "stringio"

class MigrationTest < SqliteSearch::TestCase
  # Minimal object exposing the connection so we can call the helper directly.
  class Runner
    include SqliteSearch::Migration

    def connection = ActiveRecord::Base.connection
  end

  def setup
    @conn = ActiveRecord::Base.connection
    @conn.create_table(:posts, force: true) do |t|
      t.string :title
      t.text :body
    end
  end

  def teardown
    %w[posts_by_body_fts posts_full_fts].each { |t| @conn.execute("DROP TABLE IF EXISTS #{@conn.quote_table_name(t)}") }
    @conn.execute("DROP TABLE IF EXISTS posts")
  end

  def test_creates_single_column_fts_table
    Runner.new.create_fts5_index(:posts, :by_body, against: :body)
    # AR 8.1's #tables excludes virtual tables; assert existence by querying it.
    assert_equal 0, @conn.select_value("SELECT count(*) FROM posts_by_body_fts").to_i
  end

  def test_backfills_existing_rows
    @conn.execute("INSERT INTO posts (id, body) VALUES (1, 'morning coffee')")
    Runner.new.create_fts5_index(:posts, :by_body, against: :body, backfill: true)
    count = @conn.select_value("SELECT count(*) FROM posts_by_body_fts WHERE posts_by_body_fts MATCH 'coffee'")
    assert_equal 1, count
  end

  def test_schema_dump_round_trips
    Runner.new.create_fts5_index(:posts, :full, against: {title: 2, body: 1})
    io = StringIO.new
    ActiveRecord::SchemaDumper.dump(@conn.pool, io)
    dump = io.string
    assert_match(/create_virtual_table "posts_full_fts", "fts5"/, dump)
  end
end
