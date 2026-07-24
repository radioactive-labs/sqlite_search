# frozen_string_literal: true
require "test_helper"

class HybridTest < SqliteSearch::TestCase
  def setup
    @conn = ActiveRecord::Base.connection
    @conn.create_table(:posts, force: true) { |t| t.integer :tenant_id; t.text :body }
    @conn.create_virtual_table("posts_by_body_fts", "fts5", ["body", "tokenize = 'porter unicode61'"])
    @conn.create_virtual_table("posts_semantic_vec", "vec0", ["id integer primary key", "embedding float[3] distance_metric=cosine"])
    @klass = Class.new(ActiveRecord::Base) do
      self.table_name = "posts"
      include SqliteSearch::Model
      fts5_scope :by_body, against: :body
      vec_scope :semantic, against: :body, dimensions: 3, sync: :inline
      hybrid_scope :search, fts5: :by_body, vec: :semantic
    end
    @klass.create!(id: 1, tenant_id: 1, body: "morning coffee")
    @klass.create!(id: 2, tenant_id: 1, body: "green tea")
    @klass.create!(id: 3, tenant_id: 2, body: "coffee shop")
  end

  def teardown
    %w[posts_by_body_fts posts_semantic_vec posts].each { |t| @conn.execute("DROP TABLE IF EXISTS #{@conn.quote_table_name(t)}") }
  end

  def test_returns_fused_relation_with_score
    rel = @klass.search("coffee")
    assert_kind_of ActiveRecord::Relation, rel
    rows = rel.to_a
    assert rows.any?, "expected hybrid results for 'coffee'"
    assert_respond_to rows.first, :search_score
    assert_operator rows.first.search_score, :>, 0.0
  end

  def test_blank_returns_none
    assert_equal [], @klass.search("").to_a
    assert_equal [], @klass.search(nil).to_a
  end

  def test_chained_where_prefilters_both_arms
    ids = @klass.where(tenant_id: 1).search("coffee").to_a.map(&:id)
    refute_includes ids, 3
  end

  def test_composes_with_where
    assert_kind_of ActiveRecord::Relation, @klass.search("coffee").where("tenant_id > 0")
  end

  def test_unknown_fts5_name_raises_at_declaration
    assert_raises(SqliteSearch::Error) do
      Class.new(ActiveRecord::Base) do
        self.table_name = "posts"
        include SqliteSearch::Model
        vec_scope :semantic, against: :body, dimensions: 3
        hybrid_scope :bad, fts5: :nope, vec: :semantic
      end
    end
  end

  def test_name_colliding_with_arm_scope_raises
    assert_raises(SqliteSearch::Error) do
      Class.new(ActiveRecord::Base) do
        self.table_name = "posts"
        include SqliteSearch::Model
        fts5_scope :search, against: :body
        vec_scope :semantic, against: :body, dimensions: 3
        hybrid_scope :search, fts5: :search, vec: :semantic
      end
    end
  end
end
