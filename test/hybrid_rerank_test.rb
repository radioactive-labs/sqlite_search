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

  def test_reranker_returning_empty_yields_none
    SqliteSearch.reranker { |_q, _docs, **| [] }
    assert_equal [], @klass.search("coffee").to_a
  end

  def test_reranker_injecting_unknown_records_is_ignored
    # a reranker that appends a record outside the candidate set must not leak it.
    #
    # Premise check #1: with only 3 total rows, sqlite-vec's KNN (k up to 60) pads
    # its result out to k regardless of relevance, so a body-mismatched "unrelated"
    # record still rides along as a legitimate (if weak) vec-arm candidate rather
    # than a genuinely unknown one — @klass.search("coffee", rerank: false).to_a
    # already includes id 99. Deleting its vec0 row keeps it out of both arms for
    # real (FTS never matched it; vec now has nothing to return for it), so it's
    # actually absent from the fused candidate set the reranker is handed.
    #
    # Premise check #2: prefiltering via `.where.not(id: 99)` instead would also
    # make the assertion pass, but vacuously — the final `where(primary_key =>
    # ids)` in hybrid_scope chains onto the same base relation used for the fused
    # arms, so id 99 would be excluded from the *output* by that same prefilter
    # regardless of whether the reranker-side filtering fix is present. Removing
    # the vec0 row (rather than prefiltering the relation) keeps the final query
    # unrestricted, so this test actually fails without the fix.
    other = @klass.create!(id: 99, body: "unrelated")
    @conn.execute("DELETE FROM posts_semantic_vec WHERE id = 99")
    SqliteSearch.reranker { |_q, docs, **| docs + [other] }
    ids = @klass.search("coffee").to_a.map(&:id)
    refute_includes ids, 99
  end

  def test_scored_reranker_sets_the_score
    SqliteSearch.reranker { |_q, docs, **| docs.map { |d| [d, d.id * 0.25] }.reverse }
    rows = @klass.search("coffee").to_a
    assert_equal [2, 1], rows.map(&:id)
    assert_equal [0.5, 0.25], rows.map(&:search_score)
  end

  def test_scored_reranker_order_wins_over_its_scores
    # The returned order is the result order, even if the scores disagree.
    SqliteSearch.reranker { |_q, docs, **| docs.sort_by(&:id).map { |d| [d, d.id.to_f] } }
    assert_equal [1, 2], @klass.search("coffee").pluck(:id)
  end

  def test_unscored_reranker_keeps_the_fused_score
    fused = @klass.search("coffee", rerank: false).to_a.to_h { |r| [r.id, r.search_score] }
    SqliteSearch.reranker { |_q, docs, **| docs.reverse }
    @klass.search("coffee").each { |r| assert_equal fused[r.id], r.search_score }
  end

  def test_scored_reranker_cannot_inject_records
    # Same setup as the unscored case above: drop its vector so it is a real
    # non-candidate rather than a padded KNN neighbor.
    other = @klass.create!(id: 3, body: "unrelated")
    @conn.execute("DELETE FROM posts_semantic_vec WHERE id = 3")
    SqliteSearch.reranker { |_q, docs, **| docs.map { |d| [d, 1.0] } + [[other, 9.0]] }
    refute_includes @klass.search("coffee").pluck(:id), 3
  end

  def test_reranker_repeating_a_record_does_not_shrink_the_page
    fused_order = @klass.search("coffee", rerank: false).to_a.map(&:id)
    # Repeats ahead of the second record would fill both slots with one id.
    SqliteSearch.reranker { |_q, docs, **| [docs.last, docs.last, docs.first] }
    assert_equal fused_order.reverse, @klass.search("coffee", limit: 2).to_a.map(&:id)
  end

  def test_reranker_scoring_only_some_records_degrades_to_fused_order
    fused_order = @klass.search("coffee", rerank: false).to_a.map(&:id)
    SqliteSearch.reranker { |_q, docs, **| [[docs.last, 0.9], docs.first] }
    assert_equal fused_order, @klass.search("coffee").to_a.map(&:id)
  end
end
