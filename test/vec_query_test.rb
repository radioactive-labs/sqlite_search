# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

class VecQueryTest < SqliteSearch::TestCase
  def setup
    @conn = ActiveRecord::Base.connection
    @conn.create_table(:posts, force: true) { |t| t.text :body }
    @conn.create_virtual_table("posts_semantic_vec", "vec0", ["id integer primary key", "embedding float[3] distance_metric=cosine"])
    @klass = Class.new(ActiveRecord::Base) do
      self.table_name = "posts"
      include SqliteSearch::Model

      vec_scope :semantic, against: :body, dimensions: 3
    end
    @klass.create!(id: 1, body: "morning coffee")
    @klass.create!(id: 2, body: "green tea")
    # index by hand via the internal neighbor model + stub embedder
    embed = SqliteSearch.config.embedder
    vecs = @klass.sqlite_search_vec_definitions[:semantic].neighbor_model
    {1 => "morning coffee", 2 => "green tea"}.each do |id, txt|
      vecs.create!(id: id, embedding: embed.call(txt, model: @klass, scope: :semantic))
    end
  end

  def teardown
    %w[posts_semantic_vec posts].each { |t| @conn.execute("DROP TABLE IF EXISTS #{@conn.quote_table_name(t)}") }
  end

  def test_semantic_returns_nearest_first
    assert_equal 1, @klass.semantic("coffee").to_a.first.id
  end

  def test_exposes_similarity
    top = @klass.semantic("coffee").to_a.first
    assert_respond_to top, :semantic_similarity
    assert_operator top.semantic_similarity, :>, 0.5
  end

  def test_blank_returns_none
    assert_equal [], @klass.semantic("").to_a
    assert_equal [], @klass.semantic(nil).to_a
  end

  def test_threshold_excludes_far_rows
    ids = @klass.semantic("coffee", threshold: 0.9).to_a.map(&:id)
    refute_includes ids, 2 # the "tea" row is far from a "coffee" query
  end

  def test_composes_with_where
    assert_kind_of ActiveRecord::Relation, @klass.semantic("coffee").where("id > 0")
  end

  def test_first_carries_similarity
    top = @klass.semantic("coffee").first
    assert_respond_to top, :semantic_similarity
    assert_operator top.semantic_similarity, :>, 0.5
  end

  def test_count_works
    assert_equal 2, @klass.semantic("coffee").count
  end

  def test_nearest_order_overrides_a_preceding_order
    assert_equal [2, 1], @klass.order(:id).semantic("tea").pluck(:id)
  end

  # stub embedder: "morning coffee" -> [1, 0, 0.14], "green tea" -> [0, 1, 0.09]
  def test_vector_queries_without_a_query_string
    assert_equal [1, 2], @klass.semantic(vector: [1.0, 0.0, 0.14]).pluck(:id)
    assert_equal [1], @klass.semantic(vector: [1.0, 0.0, 0.14], k: 1).pluck(:id)
  end

  def test_vector_does_not_call_the_embedder
    definition = @klass.sqlite_search_vec_definitions[:semantic]
    definition.stub(:embed, ->(*) { flunk "embedder called" }) do
      assert_equal 2, @klass.semantic(vector: [0.0, 1.0, 0.09]).first.id
    end
  end

  def test_query_and_vector_together_raise
    assert_raises(SqliteSearch::Error) { @klass.semantic("coffee", vector: [1.0, 0.0, 0.1]) }
  end

  def test_vector_with_wrong_dimensions_raises
    error = assert_raises(SqliteSearch::Error) { @klass.semantic(vector: [1.0, 0.0]) }
    assert_equal "vec_scope :semantic expects 3-dimension vectors, got 2.", error.message
  end
end
