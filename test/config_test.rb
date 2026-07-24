# frozen_string_literal: true

require "test_helper"

class ConfigTest < SqliteSearch::TestCase
  def test_embedder_is_registered_and_callable
    vec = SqliteSearch.config.embedder.call("coffee time", model: nil, scope: :semantic)
    assert_equal [1.0, 0.0, 0.11], vec
  end

  def test_vec_load_is_idempotent
    SqliteSearch::Vec.load!
    SqliteSearch::Vec.load!
    assert defined?(Neighbor::SQLite)
  end

  def test_columns_for
    assert_equal [:body], SqliteSearch::Vec.columns_for(:body)
    assert_equal [:title, :body], SqliteSearch::Vec.columns_for([:title, :body])
  end
end
