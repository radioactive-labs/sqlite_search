# frozen_string_literal: true

require "noiseless_adapter/helper"

class NoiselessUnsupportedTest < SqliteSearch::NoiselessTestCase
  NARROWING = {
    "geo filter" => ->(q) { q.geo_distance(:location, lat: 1.0, lon: 2.0, distance: "5km") },
    "search_after" => ->(q) { q.search_after([10, 1]) },
    "non-column filter" => ->(q) { q.filter(:nope, 1) },
    "image search" => ->(q) { q.image_search(:photo, "data") },
    "hash filter value" => ->(q) { q.filter(:status, {near: "x"}) },
    "inner join" => ->(q) { q.join("authors", strategy: :inner) }
  }.freeze

  DECORATIVE = {
    "aggregations" => ->(q) { q.aggregation(:by_status, :terms, field: :status) },
    "collapse" => ->(q) { q.collapse(:status) },
    "pipeline" => ->(q) { q.pipeline("rerank") },
    "conversational" => ->(q) { q.conversational(model_id: "m") },
    "joins" => ->(q) { q.join("authors") },
    "remove_duplicates" => ->(q) { q.remove_duplicates },
    "facet_sample_slope" => ->(q) { q.facet_sample_slope(2) },
    "pinned_hits" => ->(q) { q.pinned_hits({1 => 1}) },
    "non-column sort" => ->(q) { q.sort(:nope) }
  }.freeze

  NARROWING.each do |name, build|
    define_method(:"test_strict_raises_on_#{name.tr(" -", "__")}") do
      error = assert_raises(Noiseless::SearchError) { search { |q| build.call(q) } }
      assert_match(/unsupported: lax/, error.message)
    end

    define_method(:"test_lax_returns_no_hits_on_#{name.tr(" -", "__")}") do
      results = search(adapter(unsupported: :lax)) { |q| build.call(q) }
      assert_equal 0, results.total
      assert_equal [], results.ids
    end
  end

  DECORATIVE.each do |name, build|
    define_method(:"test_strict_raises_on_#{name.tr(" -", "__")}") do
      assert_raises(Noiseless::SearchError) { search { |q| build.call(q) } }
    end

    define_method(:"test_lax_skips_and_logs_#{name.tr(" -", "__")}") do
      results = nil
      log = capture_log { results = search(adapter(unsupported: :lax)) { |q| build.call(q) } }
      assert_equal %w[1 2 3 4], results.ids
      assert_match(/skipped unsupported/, log)
    end
  end

  def test_lax_logs_every_skip_in_one_line
    log = capture_log do
      search(adapter(unsupported: :lax)) { |q| q.collapse(:status).pipeline("p") }
    end
    assert_equal 1, log.lines.grep(/skipped unsupported/).size
    assert_match(/collapse.*pipeline/, log)
  end
end
