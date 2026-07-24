# frozen_string_literal: true
require "test_helper"

class HybridRerankTest < SqliteSearch::TestCase
  def setup
    @conn = ActiveRecord::Base.connection
    @conn.create_table(:posts, force: true) { |t| t.text :body }
    @conn.create_virtual_table("posts_by_body_fts", "fts5", ["body", "tokenize = 'porter unicode61'"])
    @conn.create_virtual_table("posts_semantic_vec", "vec0", ["id integer primary key", "embedding float[3] distance_metric=cosine"])
    @klass = Class.new(ActiveRecord::Base) do
      self.table_name = "posts"
      include SqliteSearch::Model
      fts5_scope :by_body, against: :body
      vec_scope :semantic, against: :body, dimensions: 3, sync: :inline
      hybrid_scope :search, fts5: :by_body, vec: :semantic
    end
    @klass.create!(id: 1, body: "coffee one")
    @klass.create!(id: 2, body: "coffee two")
    @original = SqliteSearch.config.reranker
  end

  def teardown
    SqliteSearch.config.reranker = @original
    %w[posts_by_body_fts posts_semantic_vec posts].each { |t| @conn.execute("DROP TABLE IF EXISTS #{@conn.quote_table_name(t)}") }
  end

  def test_reranker_reorders_results
    SqliteSearch.reranker { |_q, docs, **| docs.sort_by { |d| -d.id } } # force id-desc
    assert_equal [2, 1], @klass.search("coffee").to_a.map(&:id)
  end

  def test_rerank_false_skips_reranker
    SqliteSearch.reranker { |_q, _docs, **| raise "should not be called" }
    # minitest has no assert_nothing_raised; an unhandled raise here would
    # surface as a test Error, which is the failure mode we're guarding against.
    result = @klass.search("coffee", rerank: false).to_a
    assert_kind_of Array, result
  end

  def test_raising_reranker_degrades_to_fused_order
    fused_order = @klass.search("coffee", rerank: false).to_a.map(&:id)
    SqliteSearch.reranker { |_q, _docs, **| raise "boom" }
    assert_equal fused_order, @klass.search("coffee").to_a.map(&:id) # unchanged, no crash
  end

  def test_no_reranker_registered_is_plain_rrf
    SqliteSearch.config.reranker = nil
    result = @klass.search("coffee").to_a
    assert_kind_of Array, result
  end
end
