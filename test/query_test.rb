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
end
