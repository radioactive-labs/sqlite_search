# frozen_string_literal: true

require "test_helper"

class RankTest < SqliteSearch::TestCase
  def setup
    @conn = ActiveRecord::Base.connection
    @conn.create_table(:posts, force: true) { |t|
      t.string :title
      t.text :body
    }
    @conn.create_virtual_table("posts_full_fts", :fts5, ["title", "body", "tokenize = 'porter unicode61'"])
    @klass = Class.new(ActiveRecord::Base) do
      self.table_name = "posts"
      include SqliteSearch::Model

      fts5_scope :full, against: {title: 2.0, body: 1.0}
    end
    # match in body only (row 1) vs match in the higher-weighted title (row 2)
    @klass.create!(id: 1, title: "misc", body: "coffee coffee")
    @klass.create!(id: 2, title: "coffee", body: "misc")
  end

  def teardown
    %w[posts_full_fts posts].each { |t| @conn.execute("DROP TABLE IF EXISTS #{@conn.quote_table_name(t)}") }
  end

  def test_orders_by_relevance
    ids = @klass.full("coffee").order_by_rank.pluck(:id)
    assert_equal [2, 1], ids # title weight 2.0 wins
  end

  def test_exposes_rank_reader_higher_is_better
    top = @klass.full("coffee").order_by_rank.first
    assert_respond_to top, :full_rank
    assert_operator top.full_rank, :>, 0
  end

  def test_order_by_rank_safe_on_blank
    assert_equal [], @klass.full("").order_by_rank.to_a
  end

  def test_count_works_on_ranked_relation
    assert_equal 2, @klass.full("coffee").order_by_rank.count
  end

  def test_rank_overrides_a_preceding_order
    assert_equal [2, 1], @klass.order(:id).full("coffee").order_by_rank.pluck(:id)
  end

  def test_weights_follow_table_column_order_not_hash_order
    # The FTS table is (title, body); declaring the hash body-first must still
    # weight title 2.0, since bm25() applies weights by table column position.
    klass = Class.new(ActiveRecord::Base) do
      self.table_name = "posts"
      include SqliteSearch::Model

      fts5_scope :full, against: {body: 1.0, title: 2.0}
    end
    assert_equal [2, 1], klass.full("coffee").order_by_rank.pluck(:id)
  end

  def test_threshold_keeps_only_strong_matches
    ranks = @klass.full("coffee").order_by_rank.map(&:full_rank)
    cut = ranks.sum / 2
    kept = @klass.full("coffee").order_by_rank(threshold: cut).map(&:full_rank)
    assert_equal ranks.select { |r| r >= cut }, kept
    refute_equal ranks.size, kept.size
  end

  def test_threshold_is_safe_on_blank
    assert_equal [], @klass.full("").order_by_rank(threshold: 1.0).to_a
  end

  def test_columns_restricts_match_to_listed_columns
    assert_equal [2], @klass.full("coffee", columns: [:title]).pluck(:id)
  end

  def test_columns_rejects_unknown_column
    assert_raises(SqliteSearch::Error) { @klass.full("coffee", columns: [:nope]) }
  end

  def test_operator_or_widens_match
    @klass.create!(id: 3, title: "tea", body: "misc")
    assert_equal [], @klass.full("coffee tea").pluck(:id)
    assert_equal [1, 2, 3], @klass.full("coffee tea", operator: :or).order(:id).pluck(:id)
  end

  def test_minimum_should_match_and_phrase_pass_through
    @klass.create!(id: 3, title: "tea", body: "coffee coffee")
    assert_equal [3], @klass.full("coffee tea juice", minimum_should_match: 2).pluck(:id)
    assert_equal [1, 3], @klass.full("coffee coffee", phrase: true).order(:id).pluck(:id)
  end

  def test_order_by_rank_weights_override_against_weights
    # body weighted alone: row 1 (body "coffee coffee") beats row 2 (title only)
    assert_equal [1, 2], @klass.full("coffee").order_by_rank(weights: {body: 1.0}).pluck(:id)
  end

  def test_order_by_rank_weights_reject_unknown_column
    assert_raises(SqliteSearch::Error) { @klass.full("coffee").order_by_rank(weights: {nope: 1.0}) }
  end

  def test_order_by_rank_weights_reject_negative_or_non_finite
    error = assert_raises(SqliteSearch::Error) { @klass.full("coffee").order_by_rank(weights: {body: -1.0}).to_a }
    assert_match(/fts5_scope :full/, error.message)
    assert_raises(SqliteSearch::Error) { @klass.full("coffee").order_by_rank(weights: {body: Float::NAN}).to_a }
    assert_raises(SqliteSearch::Error) { @klass.full("coffee").order_by_rank(weights: {body: Float::INFINITY}).to_a }
  end

  def test_order_by_rank_unknown_weight_column_lists_the_scope_columns
    error = assert_raises(SqliteSearch::Error) { @klass.full("coffee").order_by_rank(weights: {nope: 1.0}) }
    assert_match(/fts5_scope :full has no column\(s\) nope to weight; its columns are title, body\./, error.message)
  end

  def test_order_by_rank_weights_safe_on_blank
    assert_equal [], @klass.full("").order_by_rank(weights: {body: 1.0}).to_a
  end
end
