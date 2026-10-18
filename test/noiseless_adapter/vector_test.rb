# frozen_string_literal: true

require "noiseless_adapter/helper"

class NoiselessVectorTest < SqliteSearch::NoiselessTestCase
  COFFEE = [1.0, 0.0, 0.4].freeze

  def test_knn_nearest_first_with_similarity_scores
    results = search { |q| q.vector(:semantic, COFFEE, k: 2) }
    assert_equal %w[1 3], results.ids
    assert_operator results.scores.first, :>, results.scores.last
    assert_operator results.scores.first, :<=, 1.0
    assert_equal 2, results.total
  end

  def test_filters_prefilter_the_knn
    assert_equal %w[3], search { |q| q.filter(:tenant_id, 2).vector(:semantic, COFFEE, k: 1) }.ids
  end

  def test_text_must_prefilters_the_knn
    assert_equal %w[3], search { |q| q.match(:body, "tea").vector(:semantic, COFFEE, k: 3) }.ids
  end

  def test_explicit_sort_reorders_the_knn
    assert_equal %w[1 3], search { |q| q.vector(:semantic, COFFEE, k: 2).sort(:views, :asc) }.ids
  end

  def test_pagination_pages_within_k
    results = search { |q| q.vector(:semantic, COFFEE, k: 3).paginate(page: 2, per_page: 2) }
    assert_equal %w[4], results.ids
    assert_equal 3, results.total
  end

  def test_euclidean_scores
    results = search { |q| q.vector(:nearby, [1.0, 0.0, 0.14], k: 1, distance_metric: :l2) }
    assert_equal %w[1], results.ids
    assert_in_delta 1.0, results.scores.first, 1e-6
  end

  def test_configuration_errors_raise_even_when_lax
    lax = adapter(unsupported: :lax)
    assert_raises(Noiseless::SearchError) { search(lax) { |q| q.vector(:nope, COFFEE) } }
    assert_raises(Noiseless::SearchError) { search(lax) { |q| q.vector(:nearby, COFFEE, k: 1) } }
    assert_raises(Noiseless::SearchError) { search(lax) { |q| q.vector(:semantic, COFFEE, distance_metric: :inner_product) } }
    assert_raises(Noiseless::SearchError) { search(lax) { |q| q.vector(:semantic, [1.0, 0.0]) } }
  end

  def test_hybrid_fuses_both_arms
    results = search { |q| q.hybrid("tea", COFFEE, field: :semantic, fields: %w[title body], k: 3) }
    assert_equal 3, results.total
    assert_includes results.ids, "2" # text arm only
    assert_includes results.ids, "1" # vector arm only
    assert_equal results.scores.sort.reverse, results.scores
  end

  def test_hybrid_weights_pick_the_winning_arm
    text_only = search { |q| q.hybrid("tea", COFFEE, field: :semantic, fields: %w[title body], text_weight: 1.0, vector_weight: 0.0, k: 3) }
    vector_only = search { |q| q.hybrid("tea", COFFEE, field: :semantic, fields: %w[title body], text_weight: 0.0, vector_weight: 1.0, k: 3) }
    # A zero-weight arm is not run, so its exclusive hits are absent.
    assert_equal %w[2 3], text_only.ids
    assert_equal %w[1 3 4], vector_only.ids
  end

  def test_hybrid_with_both_weights_zero_raises
    assert_raises(Noiseless::SearchError) do
      search { |q| q.hybrid("tea", COFFEE, field: :semantic, fields: %w[title body], text_weight: 0.0, vector_weight: 0.0) }
    end
  end

  # noiseless always builds the hybrid vector node as cosine; RRF fuses
  # ranks, so a euclidean vec_scope serves the vector arm too.
  def test_hybrid_over_a_euclidean_vec_scope
    assert_equal %w[2 3 1], search { |q| q.hybrid("tea", COFFEE, field: :nearby, fields: %w[title], k: 3) }.ids
  end

  def test_hybrid_needs_a_covering_text_index
    assert_raises(Noiseless::SearchError) { search { |q| q.hybrid("tea", COFFEE, field: :semantic, fields: ["status"]) } }
  end

  def test_hybrid_drops_non_column_fields_like_text_matches
    assert_raises(Noiseless::SearchError) { search { |q| q.hybrid("tea", COFFEE, field: :semantic, fields: %w[title nope], k: 3) } }
    lax = search(adapter(unsupported: :lax)) { |q| q.hybrid("tea", COFFEE, field: :semantic, fields: %w[title nope], k: 3) }
    titles = search(adapter(unsupported: :lax)) { |q| q.hybrid("tea", COFFEE, field: :semantic, fields: %w[title], k: 3) }
    assert_equal titles.ids, lax.ids
    assert_equal titles.scores, lax.scores
  end

  def test_hybrid_without_fields_needs_a_single_fts5_scope
    assert_raises(Noiseless::SearchError) { search { |q| q.hybrid("tea", COFFEE, field: :semantic) } }
  end

  def test_hybrid_without_fields_uses_the_only_fts5_scope
    model = Class.new(ActiveRecord::Base) do
      self.table_name = "posts"
      include SqliteSearch::Model

      fts5_scope :text, against: {title: 2.0, body: 1.0}
      vec_scope :semantic, against: [:title, :body], dimensions: 3, sync: :manual
    end
    single = ::Noiseless::Adapters::Sqlite.new.tap { |a| a.register_model(model, index_name: "posts") }
    assert_equal %w[3 2 1], search(single) { |q| q.hybrid("tea", COFFEE, field: :semantic, k: 3) }.ids
  end

  def test_hybrid_respects_filters
    assert_equal %w[2 1], search { |q| q.filter(:tenant_id, 1).hybrid("tea", COFFEE, field: :semantic, fields: %w[title body], k: 4) }.ids
  end
end
