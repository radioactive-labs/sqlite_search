# frozen_string_literal: true
require "test_helper"
require "stringio"

class VecMigrationTest < SqliteSearch::TestCase
  class Runner
    include SqliteSearch::Migration
    def connection = ActiveRecord::Base.connection
  end

  def setup
    @conn = ActiveRecord::Base.connection
    @conn.create_table(:posts, force: true) { |t| t.text :body }
  end

  def teardown
    %w[posts_semantic_vec posts].each { |t| @conn.execute("DROP TABLE IF EXISTS #{@conn.quote_table_name(t)}") }
  end

  def test_creates_vec0_table
    Runner.new.create_vec_index(:posts, :semantic, dimensions: 3)
    assert_equal 0, @conn.select_value("SELECT count(*) FROM posts_semantic_vec").to_i
  end

  def test_schema_dump_round_trips
    Runner.new.create_vec_index(:posts, :semantic, dimensions: 3)
    io = StringIO.new
    ActiveRecord::SchemaDumper.dump(@conn.pool, io)
    assert_match(/create_virtual_table "posts_semantic_vec", "vec0"/, io.string)
  end
end
