# frozen_string_literal: true

require "test_helper"

class QueryTest < SqliteSearch::TestCase
  B = SqliteSearch::Query

  def test_bare_words_are_anded
    assert_equal "coffee AND shop", B.build("coffee shop")
  end

  def test_quoted_phrase_preserved
    assert_equal '"flat white"', B.build('"flat white"')
  end

  def test_phrase_and_word
    assert_equal '"flat white" AND decaf', B.build('"flat white" decaf')
  end

  def test_operators_are_stripped_from_bare_text
    assert_equal "a AND b AND c", B.build("a OR b* NOT c")
  end

  def test_prefix_appends_star_to_last_term
    assert_equal "flat AND white*", B.build("flat white", prefix: true)
  end

  def test_blank_returns_nil
    assert_nil B.build("")
    assert_nil B.build("   ")
    assert_nil B.build("*** ---")
  end

  def test_invalid_encoding_does_not_raise
    input = (+"coffee \xFF\xFE shop").force_encoding("UTF-8")
    assert_equal "coffee AND shop", B.build(input)
  end

  def test_unbalanced_quote_falls_back_to_bare_words
    assert_equal "a AND b", B.build('a "b')
  end

  def test_lone_quote_returns_nil
    assert_nil B.build('"')
  end

  def test_column_filter_syntax_neutralized
    assert_equal "body AND foo", B.build("body:foo")
  end

  def test_lowercase_operators_kept_as_literal_terms
    assert_equal "a AND and AND b", B.build("a and b")
  end

  def test_terms_keep_the_order_they_were_typed
    assert_equal 'decaf AND "flat white"', B.build('decaf "flat white"')
  end

  def test_prefix_skips_a_trailing_phrase
    assert_equal 'cat AND "black dog"', B.build('cat "black dog"', prefix: true)
  end

  def test_prefix_widens_a_word_typed_after_a_phrase
    assert_equal '"black dog" AND cat*', B.build('"black dog" cat', prefix: true)
  end

  def test_empty_quotes_do_not_swallow_the_text_after_them
    assert_equal 'a AND b AND "c d"', B.build('a "" b "c d"')
  end

  def test_or_operator_joins_terms_with_or
    assert_equal "hot OR coffee", B.build("hot coffee", operator: :or)
    assert_equal "hot OR coffee", B.build("hot coffee", operator: "or")
  end

  def test_prefix_combines_with_or
    assert_equal "flat OR whi*", B.build("flat whi", operator: :or, prefix: true)
  end

  def test_unknown_operator_raises
    assert_raises(SqliteSearch::Error) { B.build("a", operator: :xor) }
    assert_raises(SqliteSearch::Error) { B.build("a", operator: nil) }
  end

  def test_phrase_joins_every_word_into_one_phrase
    assert_equal '"flat white decaf"', B.build('"flat white" decaf', phrase: true)
  end

  def test_phrase_with_prefix_stars_the_phrase
    assert_equal '"flat whi" *', B.build("flat whi", phrase: true, prefix: true)
  end

  def test_minimum_should_match_expands_combinations
    assert_equal "(a AND b) OR (a AND c) OR (b AND c)", B.build("a b c", minimum_should_match: 2)
  end

  def test_minimum_should_match_accepts_percent_and_negative_forms
    three_of_four = B.build("a b c d", minimum_should_match: 3)
    assert_equal "(a AND b AND c) OR (a AND b AND d) OR (a AND c AND d) OR (b AND c AND d)", three_of_four
    assert_equal three_of_four, B.build("a b c d", minimum_should_match: "75%")
    assert_equal three_of_four, B.build("a b c d", minimum_should_match: -1)
    assert_equal three_of_four, B.build("a b c d", minimum_should_match: "-25%")
    assert_equal three_of_four, B.build("a b c d", minimum_should_match: "3")
  end

  def test_minimum_should_match_collapses_at_the_ends
    assert_equal "a AND b", B.build("a b", minimum_should_match: 2)
    assert_equal "a OR b", B.build("a b", minimum_should_match: 1)
    assert_equal "a AND b", B.build("a b", minimum_should_match: 5)
    assert_equal "a OR b", B.build("a b", minimum_should_match: "10%")
  end

  def test_required_terms_follows_elasticsearch_rules
    assert_equal 3, B.required_terms("75%", 4)
    assert_equal 3, B.required_terms(-1, 4)
    assert_equal 2, B.required_terms(5, 2)
    assert_equal 1, B.required_terms("10%", 2)
    assert_raises(SqliteSearch::Error) { B.required_terms("most", 3) }
  end

  def test_minimum_should_match_stars_prefix_before_expanding
    assert_equal "(a AND b) OR (a AND c*) OR (b AND c*)", B.build("a b c", minimum_should_match: 2, prefix: true)
  end

  def test_minimum_should_match_on_a_single_term
    assert_equal "a", B.build("a", minimum_should_match: 2)
  end

  def test_minimum_should_match_over_cap_raises
    assert_raises(SqliteSearch::Query::TooManyTerms) { B.build("a b c d e f g", minimum_should_match: 3) }
    assert_equal "a AND b AND c AND d AND e AND f AND g", B.build("a b c d e f g", minimum_should_match: 7)
  end

  def test_minimum_should_match_rejects_garbage
    assert_raises(SqliteSearch::Error) { B.build("a b", minimum_should_match: "most") }
  end

  def test_columns_wrap_expression_in_a_column_filter
    assert_equal '{"title" "body"} : (hot AND coffee)', B.build("hot coffee", columns: %w[title body])
    assert_equal "hot AND coffee", B.build("hot coffee", columns: [])
  end

  def test_options_keep_input_sanitized
    assert_equal '{"title"} : (a OR b OR c)', B.build("a NEAR( b* ) OR c", operator: :or, columns: [:title])
  end
end
