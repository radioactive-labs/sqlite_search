# frozen_string_literal: true

require "test_helper"

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
end
