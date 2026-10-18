# frozen_string_literal: true

require "noiseless_adapter/helper"

class NoiselessResponseTest < SqliteSearch::NoiselessTestCase
  def test_build_shapes_hits_and_drops_score_columns
    record = @model.select("posts.*, 7.5 AS text_rank").find(1)
    raw = SqliteSearch::NoiselessAdapter::Response.build(
      [record], model: @model, total: 1, scorer: ->(r) { r.text_rank },
      score_columns: ["text_rank"], started: Process.clock_gettime(Process::CLOCK_MONOTONIC)
    )
    hit = raw["hits"]["hits"].first
    assert_equal "posts", hit["_index"]
    assert_equal "1", hit["_id"]
    assert_equal 7.5, hit["_score"]
    assert_equal "Morning coffee", hit["_source"]["title"]
    refute hit["_source"].key?("text_rank")
    assert_equal 7.5, raw["hits"]["max_score"]
    assert_equal({"value" => 1, "relation" => "eq"}, raw["hits"]["total"])
    assert_kind_of Integer, raw["took"]
  end

  def test_source_is_json_typed_without_a_root
    model = Class.new(@model) { attribute :seen_at, :datetime, default: -> { Time.utc(2026, 1, 2, 3, 4, 5) } }
    model.include_root_in_json = true
    raw = SqliteSearch::NoiselessAdapter::Response.build(
      [model.find(1)], model: model, total: 1, scorer: ->(_) { 1.0 },
      score_columns: [], started: Process.clock_gettime(Process::CLOCK_MONOTONIC)
    )
    source = raw["hits"]["hits"].first["_source"]
    assert_equal "Morning coffee", source["title"]
    assert_equal "2026-01-02T03:04:05.000Z", source["seen_at"]
  end

  def test_empty_response
    raw = SqliteSearch::NoiselessAdapter::Response.empty(started: Process.clock_gettime(Process::CLOCK_MONOTONIC))
    assert_equal 0, raw["hits"]["total"]["value"]
    assert_nil raw["hits"]["max_score"]
    assert_equal [], raw["hits"]["hits"]
  end
end
