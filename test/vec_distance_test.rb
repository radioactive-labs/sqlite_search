# frozen_string_literal: true

require "test_helper"

class VecDistanceTest < SqliteSearch::TestCase
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

  def klass_for(distance)
    Runner.new.create_vec_index(:posts, :semantic, dimensions: 3, distance: distance)
    Class.new(ActiveRecord::Base) do
      self.table_name = "posts"
      include SqliteSearch::Model

      vec_scope :semantic, against: :body, dimensions: 3, distance: distance, sync: :inline
    end
  end

  def test_euclidean_ranks_by_distance_and_exposes_distance_reader
    k = klass_for(:euclidean)
    k.create!(id: 1, body: "coffee") # stub vector matches the "coffee" query
    k.create!(id: 2, body: "tea")
    top = k.semantic("coffee").to_a.first
    assert_equal 1, top.id
    assert_respond_to top, :semantic_distance
    assert_operator top.semantic_distance, :>=, 0.0
    refute_respond_to top, :semantic_similarity # similarity is cosine-only
  end

  def test_euclidean_threshold_is_a_distance_ceiling
    k = klass_for(:euclidean)
    k.create!(id: 1, body: "coffee") # distance ~0 from the "coffee" query
    k.create!(id: 2, body: "tea")    # far
    ids = k.semantic("coffee", threshold: 0.5).to_a.map(&:id) # keep distance <= 0.5
    assert_equal [1], ids
  end

  def test_taxicab_is_supported
    k = klass_for(:taxicab)
    k.create!(id: 1, body: "coffee")
    assert_equal 1, k.semantic("coffee").to_a.first.id
  end

  def test_cosine_exposes_both_distance_and_similarity
    k = klass_for(:cosine)
    k.create!(id: 1, body: "coffee")
    top = k.semantic("coffee").to_a.first
    assert_respond_to top, :semantic_distance
    assert_respond_to top, :semantic_similarity
    assert_in_delta 1.0 - top.semantic_distance, top.semantic_similarity, 1e-9
  end

  def test_unsupported_distance_raises_at_declaration
    err = assert_raises(SqliteSearch::Error) do
      Class.new(ActiveRecord::Base) do
        self.table_name = "posts"
        include SqliteSearch::Model

        vec_scope :semantic, against: :body, dimensions: 3, distance: :inner_product
      end
    end
    assert_match(/Unsupported distance/, err.message)
  end

  def test_create_vec_index_rejects_unsupported_distance
    err = assert_raises(SqliteSearch::Error) do
      Runner.new.create_vec_index(:posts, :semantic, dimensions: 3, distance: :hamming)
    end
    assert_match(/Unsupported distance/, err.message)
  end
end
