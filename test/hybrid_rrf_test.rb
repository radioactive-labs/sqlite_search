# frozen_string_literal: true

require "test_helper"

class HybridRrfTest < SqliteSearch::TestCase
  def test_default_weights_match_neighbor_scores
    a = [1, 2, 3]
    b = [3, 4, 1]
    expected = Neighbor::Reranking.rrf(a.map { |id| {id: id} }, b.map { |id| {id: id} })
      .to_h { |row| [row[:result][:id], row[:score]] }
    fused = SqliteSearch::Hybrid.rrf(a, b)
    assert_equal expected.keys.sort, fused.map(&:first).sort
    fused.each { |id, score| assert_in_delta expected[id], score, 1e-12 }
  end

  def test_weights_scale_each_arm
    assert_equal [[1, 2.0 / 61], [2, 1.0 / 61]], SqliteSearch::Hybrid.rrf([1], [2], weights: [2.0, 1.0])
  end

  def test_ties_break_by_first_appearance
    assert_equal [1, 2], SqliteSearch::Hybrid.rrf([1], [2]).map(&:first)
    assert_equal [2, 1], SqliteSearch::Hybrid.rrf([2], [1]).map(&:first)
  end

  def test_zero_weight_arm_is_excluded
    assert_equal [[1, 1.0 / 61]], SqliteSearch::Hybrid.rrf([1], [2], weights: [1.0, 0])
    assert_equal [[2, 1.0 / 61]], SqliteSearch::Hybrid.rrf([1], [2], weights: [0, 1.0])
  end

  def test_rejects_weights_without_two_entries
    assert_raises(SqliteSearch::Error) { SqliteSearch::Hybrid.rrf([1], [2], weights: [1.0]) }
    assert_raises(SqliteSearch::Error) { SqliteSearch::Hybrid.rrf([1], [2], weights: [1.0, 1.0, 1.0]) }
  end

  def test_rejects_invalid_weights
    assert_raises(SqliteSearch::Error) { SqliteSearch::Hybrid.rrf([1], [2], weights: [-1.0, 1.0]) }
    assert_raises(SqliteSearch::Error) { SqliteSearch::Hybrid.rrf([1], [2], weights: [0, 0]) }
    assert_raises(SqliteSearch::Error) { SqliteSearch::Hybrid.rrf([1], [2], weights: [Float::INFINITY, 1.0]) }
  end
end
