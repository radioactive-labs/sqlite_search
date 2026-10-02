# frozen_string_literal: true

require "test_helper"

class VecReembedTest < SqliteSearch::TestCase
  def setup
    @conn = ActiveRecord::Base.connection
    @conn.create_table(:posts, force: true) { |t| t.text :body }
    @conn.create_virtual_table("posts_semantic_vec", "vec0", ["id integer primary key", "embedding float[3] distance_metric=cosine"])
    @klass = Class.new(ActiveRecord::Base) do
      self.table_name = "posts"
      include SqliteSearch::Model

      vec_scope :semantic, against: :body, dimensions: 3, sync: :inline
    end
  end

  def teardown
    %w[posts_semantic_vec posts].each { |t| @conn.execute("DROP TABLE IF EXISTS #{@conn.quote_table_name(t)}") }
  end

  def vec_count = @conn.select_value("SELECT count(*) FROM posts_semantic_vec").to_i

  def test_reembed_named_scope_recovers_bulk_inserts
    @klass.insert_all([{id: 1, body: "coffee"}, {id: 2, body: "tea"}])
    assert_equal 0, vec_count # insert_all bypassed the sync callback
    @klass.reembed(:semantic)
    assert_equal 2, vec_count
    assert_equal 1, @klass.semantic("coffee").to_a.first.id
  end

  def test_reembed_all_scopes
    @klass.insert_all([{id: 1, body: "coffee"}])
    @klass.reembed
    assert_equal 1, vec_count
  end

  def test_failed_reembed_keeps_existing_vectors
    @klass.create!(id: 1, body: "coffee")
    @klass.create!(id: 2, body: "tea")
    failing = Class.new(ActiveRecord::Base) do
      self.table_name = "posts"
      include SqliteSearch::Model

      vec_scope :semantic, against: :body, dimensions: 3, sync: :inline,
        embedder: ->(text, **) {
          raise "embedder down" if text == "tea"
          [1.0, 0.0, 0.0]
        }
    end
    assert_raises(RuntimeError) { failing.reembed }
    assert_equal 2, vec_count
  end

  def test_reembed_removes_vectors_for_deleted_rows
    @klass.create!(id: 1, body: "coffee")
    @klass.where(id: 1).delete_all # skips the destroy callback
    @klass.reembed
    assert_equal 0, vec_count
  end

  def test_reembed_ignores_default_scope
    scoped = Class.new(ActiveRecord::Base) do
      self.table_name = "posts"
      include SqliteSearch::Model

      default_scope { where.not(body: "tea") }
      vec_scope :semantic, against: :body, dimensions: 3, sync: :inline
    end
    scoped.insert_all([{id: 1, body: "coffee"}, {id: 2, body: "tea"}])
    scoped.reembed
    assert_equal 2, vec_count
  end
end
