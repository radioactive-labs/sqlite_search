# frozen_string_literal: true

require "noiseless_adapter/helper"
require "minitest/mock"

class NoiselessAdapterTest < SqliteSearch::NoiselessTestCase
  def test_lookup_by_name_returns_the_sqlite_adapter
    assert_instance_of Noiseless::Adapters::Sqlite, Noiseless::Adapters.lookup("sqlite", hosts: [])
  end

  def test_unsupported_mode_accepts_strings_and_rejects_others
    assert_instance_of Noiseless::Adapters::Sqlite, Noiseless::Adapters::Sqlite.new(unsupported: "lax")
    assert_raises(ArgumentError) { Noiseless::Adapters::Sqlite.new(unsupported: "loose") }
  end

  def test_filters_paginate_and_count_before_paging
    results = search { |q| q.filter(:status, "published").paginate(page: 1, per_page: 2) }
    assert_equal %w[1 3], results.ids
    assert_equal 3, results.total
    assert_equal [1.0, 1.0], results.scores
  end

  def test_second_page
    assert_equal %w[3 4], search { |q| q.paginate(page: 2, per_page: 2) }.ids
  end

  def test_array_and_range_filters
    assert_equal %w[1 2], search { |q| q.filter(:id, [1, 2]) }.ids
    assert_equal %w[1 3], search { |q| q.filter(:views, {gte: 10}) }.ids
    assert_equal %w[2], search { |q| q.filter(:views, {gt: 1, lt: 10}) }.ids
  end

  def test_nil_range_bound_is_open_ended
    assert_equal %w[1 3], search { |q| q.filter(:views, {gte: 10, lte: nil}) }.ids
  end

  def test_sort_with_primary_key_tiebreak
    @model.find(4).update!(views: 20)
    assert_equal %w[3 4 1 2], search { |q| q.sort(:views, :desc) }.ids
  end

  def test_unknown_sort_direction_raises
    error = assert_raises(Noiseless::SearchError) { search { |q| q.sort(:views, :sideways) } }
    assert_match(/sort direction must be asc or desc/, error.message)
  end

  def test_sort_on_id_uses_the_primary_key
    assert_equal %w[4 3 2 1], search { |q| q.sort(:_id, :desc) }.ids
  end

  def test_sort_on_score_without_relevance_falls_back_to_primary_key
    assert_equal %w[1 2 3 4], search { |q| q.sort(:_score, :desc) }.ids
  end

  def test_sort_on_score_without_relevance_falls_through_to_later_sorts
    assert_equal %w[3 1 2 4], search { |q| q.sort(:_score, :desc).sort(:views, :desc) }.ids
  end

  def test_sort_on_score_first_keeps_relevance_order
    ranked = search { |q| q.match(:title, "coffee") }.ids
    # Give the best match the fewest views, so a views sort would flip them.
    @model.find(ranked.first).update!(views: 0)
    @model.find(ranked.last).update!(views: 100)
    assert_equal ranked, search { |q| q.match(:title, "coffee").sort(:_score, :desc).sort(:views, :desc) }.ids
  end

  def test_sorts_after_score_break_relevance_ties
    @model.create!(id: 5, title: "espresso", views: 1)
    @model.create!(id: 6, title: "espresso", views: 9)
    assert_equal %w[5 6], search { |q| q.match(:title, "espresso") }.ids
    assert_equal %w[6 5], search { |q| q.match(:title, "espresso").sort(:_score, :desc).sort(:views, :desc) }.ids
  end

  def test_sort_on_score_ascending_is_unsupported
    error = assert_raises(Noiseless::SearchError) { search { |q| q.sort(:_score) } }
    assert_match(/sort on _score ascending/, error.message)
    assert_equal %w[1 2 3 4], search(adapter(unsupported: :lax)) { |q| q.sort(:_score, :asc) }.ids
  end

  def test_sort_on_score_after_other_fields_is_unsupported
    error = assert_raises(Noiseless::SearchError) { search { |q| q.sort(:title).sort(:_score, :desc) } }
    assert_match(/sort on _score after other fields/, error.message)
    assert_equal %w[4 3 2 1], search(adapter(unsupported: :lax)) { |q| q.sort(:title).sort(:_score, :desc) }.ids
  end

  def test_default_window_is_twenty_rows
    @model.insert_all((5..25).map { |id| {id: id, title: "post #{id}", status: "draft", views: 0, tenant_id: 1} })
    results = search { |q| q.filter(:tenant_id, [1, 2]) }
    assert_equal (1..20).map(&:to_s), results.ids
    assert_equal 25, results.total
  end

  def test_sources_carry_the_row
    assert_equal "Morning coffee", search { |q| q.filter(:id, 1) }.sources.first[:title]
  end

  def test_active_record_model_class_wins
    adapter = Noiseless::Adapters::Sqlite.new
    ast = ::Noiseless::QueryBuilder.new(@search).filter(:id, 1).to_ast
    # An ActiveRecord model_class makes noiseless load records, not results.
    assert_equal [1], Sync { adapter.search(ast, model_class: @model).wait }.to_a.map(&:id)
  end

  def test_resolves_model_by_index_name_constant
    Object.const_set(:Post, @model)
    assert_equal %w[2], search(Noiseless::Adapters::Sqlite.new) { |q| q.filter(:id, 2) }.ids
  ensure
    Object.send(:remove_const, :Post)
  end

  def test_raises_when_no_model_resolves
    adapter = Noiseless::Adapters::Sqlite.new
    error = assert_raises(Noiseless::SearchError) { search(adapter) { |q| q.filter(:id, 1) } }
    assert_match(/no ActiveRecord model for index "posts"/, error.message)
  end

  def test_runs_through_a_named_connection
    Noiseless.connections.register(:sqlite_named, adapter: "sqlite", hosts: [], unsupported: "strict")
    Noiseless.connections.client(:sqlite_named).register_model(@model, index_name: "posts")
    @search.connection(:sqlite_named)
    assert_equal %w[2], @search.new.filter(:status, "draft").execute_sync.ids
  end

  def test_wraps_connection_errors
    @model.stub(:with_connection, ->(*) { raise ActiveRecord::ConnectionNotEstablished, "gone" }) do
      assert_raises(Noiseless::ConnectionError) { search { |q| q.filter(:id, 1) } }
    end
  end

  def test_wraps_database_errors
    @conn.drop_table(:posts)
    error = assert_raises(Noiseless::SearchError) { search { |q| q.filter(:id, 1) } }
    assert_kind_of ActiveRecord::StatementInvalid, error.cause
  end

  def test_raw_queries_are_refused
    assert_raises(Noiseless::SearchError) { @adapter.search_raw({query: {}}, indexes: ["posts"]) }
  end

  def test_document_writes_are_noops
    Sync do
      assert_equal "noop", @adapter.index_document(index: "posts", id: 1, document: {title: "x"}).wait["result"]
      assert_equal "noop", @adapter.update_document(index: "posts", id: 1, changes: {title: "x"}).wait["result"]
      assert_equal "noop", @adapter.delete_document(index: "posts", id: 1).wait["result"]
      bulk = @adapter.bulk([{index: {_index: "posts", _id: 1, data: {}}}]).wait
      assert_equal({"index" => {"_index" => "posts", "_id" => 1, "result" => "noop"}}, bulk["items"].first)
      refute bulk["errors"]
    end
    assert_equal "Morning coffee", @model.find(1).title
    assert_equal 4, @model.count
  end

  def test_existence_checks_and_health
    Sync do
      assert @adapter.index_exists?("posts").wait
      refute @adapter.index_exists?("nope").wait
      assert @adapter.document_exists?(index: "posts", id: 1).wait
      refute @adapter.document_exists?(index: "posts", id: 99).wait
    end
    assert_equal "green", @adapter.cluster.health["status"]
  end
end
