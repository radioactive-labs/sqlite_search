# frozen_string_literal: true
require "test_helper"

class VecPrefilterTest < SqliteSearch::TestCase
  def setup
    @conn = ActiveRecord::Base.connection
    @conn.create_table(:posts, force: true) { |t| t.integer :tenant_id; t.text :body }
    @conn.create_virtual_table("posts_semantic_vec", "vec0", ["id integer primary key", "embedding float[3] distance_metric=cosine"])
    @klass = Class.new(ActiveRecord::Base) do
      self.table_name = "posts"
      include SqliteSearch::Model
      vec_scope :semantic, against: :body, dimensions: 3, sync: :inline
    end
    # id 3 is closest to a "coffee" query but in tenant 2
    @klass.create!(id: 1, tenant_id: 1, body: "morning coffee")
    @klass.create!(id: 2, tenant_id: 1, body: "green tea")
    @klass.create!(id: 3, tenant_id: 2, body: "coffee coffee coffee")
  end

  def teardown
    %w[posts_semantic_vec posts].each { |t| @conn.execute("DROP TABLE IF EXISTS #{@conn.quote_table_name(t)}") }
  end

  def test_unchained_returns_global_nearest
    assert_includes @klass.semantic("coffee").to_a.map(&:id), 3
  end

  def test_chained_where_prefilters_knn
    ids = @klass.where(tenant_id: 1).semantic("coffee").to_a.map(&:id)
    refute_includes ids, 3
    assert_equal 1, ids.first
  end

  def test_chained_still_exposes_similarity
    top = @klass.where(tenant_id: 1).semantic("coffee").to_a.first
    assert_operator top.semantic_similarity, :>, 0.5
  end
end
