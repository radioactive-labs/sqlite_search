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
end
