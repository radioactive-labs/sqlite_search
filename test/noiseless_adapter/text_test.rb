# frozen_string_literal: true

require "noiseless_adapter/helper"

class NoiselessTextTest < SqliteSearch::NoiselessTestCase
  def test_match_uses_covering_fts_index_with_rank_scores
    results = search { |q| q.match(:title, "coffee") }
    assert_equal %w[1 3], results.ids.sort
    assert results.scores.all?(&:positive?)
    assert_equal results.scores.sort.reverse, results.scores
  end

  def test_match_defaults_to_or_like_elasticsearch
    assert_equal %w[1 2 3], search { |q| q.match(:title, "coffee tea") }.ids.sort
  end

  def test_multi_match_operator_and
    assert_equal %w[3], search { |q| q.multi_match("coffee tea", %w[title body], operator: "and") }.ids
  end

  def test_multi_match_restricts_to_listed_columns
    assert_equal %w[2], search { |q| q.multi_match("tea", ["title"]) }.ids
    assert_equal %w[3], search { |q| q.multi_match("tea", ["body"]) }.ids
  end

  def test_combined_fields_operator
    assert_equal %w[3], search { |q| q.combined_fields("coffee tea", %w[title body], operator: "and") }.ids
  end

  def test_phrase_types
    assert_equal %w[3], search { |q| q.multi_match("coffee and tea", ["body"], type: "phrase") }.ids
    assert_equal [], search { |q| q.multi_match("tea and coffee", ["body"], type: "phrase") }.ids
    assert_equal %w[3], search { |q| q.multi_match("coffee and te", ["body"], type: "phrase_prefix") }.ids
    assert_equal %w[1 3], search { |q| q.multi_match("coff", ["title"], type: "bool_prefix") }.ids.sort
    assert_equal %w[1 2 3], search { |q| q.multi_match("coffee tea", %w[title body], type: "cross_fields") }.ids.sort
  end

  def test_field_boosts_set_per_query_weights
    assert_equal %w[1 3], search { |q| q.multi_match("coffee", ["title^1", "body^0"]) }.ids
    results = search { |q| q.multi_match("coffee", ["title^0", "body^1"]) }
    assert_equal 0.0, results.scores[results.ids.index("1")]
  end

  def test_minimum_should_match
    assert_equal %w[3], search { |q| q.multi_match("coffee tea orange", %w[title body], minimum_should_match: 2) }.ids
  end

  def test_combined_fields_minimum_should_match
    assert_equal %w[3], search { |q| q.combined_fields("coffee tea orange", %w[title body], minimum_should_match: 2) }.ids
  end

  def test_minimum_should_match_over_cap
    query = "coffee tea guide shop where find good"
    assert_raises(Noiseless::SearchError) do
      search { |q| q.multi_match(query, %w[title body], minimum_should_match: 2) }
    end
    lax = search(adapter(unsupported: :lax)) { |q| q.multi_match(query, %w[title body], minimum_should_match: 2) }
    assert_equal %w[3], lax.ids
  end

  def test_zero_terms_query
    assert_equal [], search { |q| q.multi_match("!!!", ["title"]) }.ids
    assert_equal 4, search { |q| q.multi_match("!!!", ["title"], zero_terms_query: "all") }.total
  end

  def test_fuzziness_strict_raises_lax_ignores
    assert_raises(Noiseless::SearchError) { search { |q| q.multi_match("coffee", ["title"], fuzziness: "AUTO") } }
    lax = search(adapter(unsupported: :lax)) { |q| q.multi_match("coffee", ["title"], fuzziness: "AUTO") }
    assert_equal %w[1 3], lax.ids.sort
  end

  def test_scoring_only_options_are_ignored
    assert_equal %w[1 3], search { |q| q.multi_match("coffee", ["title"], boost: 2, tie_breaker: 0.3) }.ids.sort
  end

  def test_like_fallback_on_uncovered_text_column
    results = search { |q| q.match(:status, "publish") }
    assert_equal %w[1 3 4], results.ids
    assert_equal [1.0, 1.0, 1.0], results.scores
  end

  def test_like_fallback_on_non_text_field_is_narrowing
    assert_raises(Noiseless::SearchError) { search { |q| q.match(:views, "10") } }
    assert_equal [], search(adapter(unsupported: :lax)) { |q| q.match(:views, "10") }.ids
  end

  def test_like_fallback_operator
    assert_equal [], search { |q| q.multi_match("pub draft", ["status"], operator: "and") }.ids
    assert_equal %w[1 2 3 4], search { |q| q.multi_match("pub draft", ["status"], operator: "or") }.ids
  end

  def test_invalid_operator_raises
    assert_raises(Noiseless::SearchError) { search { |q| q.multi_match("publish", ["status"], operator: "xor") } }
  end

  def test_like_fallback_minimum_should_match
    assert_equal %w[1 2 3 4], search { |q| q.multi_match("publish draft xyz", ["status"], minimum_should_match: 1) }.ids
    assert_equal %w[1 3 4], search { |q| q.multi_match("publish published", ["status"], minimum_should_match: 2) }.ids
    assert_raises(Noiseless::SearchError) do
      search { |q| q.multi_match("publish draft xyz", ["status"], minimum_should_match: 2) }
    end
    results = nil
    log = capture_log do
      results = search(adapter(unsupported: :lax)) { |q| q.multi_match("publish draft xyz", ["status"], minimum_should_match: 2) }
    end
    assert_equal [], results.ids
    assert_match(/minimum_should_match on LIKE fallback/, log)
  end

  def test_like_fallback_phrase_drops_quotes
    assert_equal %w[1 3 4], search { |q| q.multi_match('"publish"', ["status"], type: "phrase") }.ids
  end

  def test_non_column_text_field_is_dropped_before_covering_lookup
    assert_raises(Noiseless::SearchError) { search { |q| q.multi_match("coffee", %w[title nonexistent]) } }
    results = nil
    log = capture_log do
      results = search(adapter(unsupported: :lax)) { |q| q.multi_match("coffee", %w[title nonexistent]) }
    end
    assert_equal %w[1 3], results.ids.sort
    assert results.scores.all? { |score| score.positive? && score < 1.0 }
    assert_match(/text match on non-column field nonexistent/, log)
  end

  def test_only_non_column_text_fields_is_narrowing
    assert_raises(Noiseless::SearchError) { search { |q| q.multi_match("coffee", ["nonexistent"]) } }
    assert_equal [], search(adapter(unsupported: :lax)) { |q| q.multi_match("coffee", ["nonexistent"]) }.ids
  end

  def test_wildcard_and_prefix_escape_like_characters
    assert_equal %w[4], search { |q| q.wildcard(:title, "100%*") }.ids
    assert_equal %w[4], search { |q| q.wildcard(:title, "*_box") }.ids
    assert_equal [], search { |q| q.wildcard(:title, "*x_box") }.ids
    assert_equal %w[3], search { |q| q.prefix(:title, "Coff") }.ids
    assert_equal %w[2], search { |q| q.wildcard(:title, "Green te?") }.ids
  end

  def test_ranked_match_with_wildcard_on_same_column
    results = search { |q| q.match(:title, "coffee").wildcard(:title, "*e*") }
    assert_equal %w[1 3], results.ids.sort
    assert results.scores.all?(&:positive?)
  end

  def test_range_must
    assert_equal %w[1 3], search { |q| q.range(:views, gte: 10) }.ids
  end

  def test_text_and_filter_combine
    assert_equal %w[1], search { |q| q.match(:title, "coffee").filter(:tenant_id, 1) }.ids
  end

  def test_two_text_clauses_and_together_with_constant_score
    results = search { |q| q.match(:title, "coffee").match(:body, "tea") }
    assert_equal %w[3], results.ids
    assert_equal [1.0], results.scores
  end

  def test_explicit_sort_overrides_rank
    assert_equal %w[3 1], search { |q| q.match(:title, "coffee").sort(:views, :desc) }.ids
  end

  def test_like_fallback_reports_dropped_non_text_fields
    assert_raises(Noiseless::SearchError) { search { |q| q.multi_match("publish", %w[status views]) } }
    results = nil
    log = capture_log { results = search(adapter(unsupported: :lax)) { |q| q.multi_match("publish", %w[status views]) } }
    assert_equal %w[1 3 4], results.ids
    assert_match(/non-text field views/, log)
  end
end
