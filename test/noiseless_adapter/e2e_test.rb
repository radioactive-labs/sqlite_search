# frozen_string_literal: true

require "noiseless_adapter/helper"
require "tempfile"
require "minitest/mock"

# Drives the adapter the way a noiseless app does: connections come from
# noiseless.yml through Noiseless.connections, and searches run through a
# Noiseless::Model search class rather than the adapter directly.
class NoiselessE2ETest < SqliteSearch::NoiselessTestCase
  CONFIG = <<~YAML
    #{ENV.fetch("RAILS_ENV", "development")}:
      connections:
        e2e_strict:
          adapter: sqlite
          unsupported: strict
        e2e_lax:
          adapter: sqlite
          unsupported: lax
  YAML

  def setup
    super
    @config_file = Tempfile.new(["noiseless", ".yml"])
    @config_file.write(CONFIG)
    @config_file.close
    @config_path = ::Noiseless.config.config_path
    ::Noiseless.config.config_path = @config_file.path
    load_configuration
    %i[e2e_strict e2e_lax].each { |name| ::Noiseless.connections.client(name).register_model(@model, index_name: "posts") }

    @posts = Class.new(::Noiseless::Model) do
      index_name "posts"
      connection :e2e_strict

      def by_text(query) = multi_match(query, %w[title body])

      def published = filter(:status, "published")
    end
  end

  def teardown
    ::Noiseless.config.config_path = @config_path if @config_file
    @config_file&.unlink
    super
  end

  # The generator tests load railties without an app, leaving Rails.root nil,
  # and noiseless's loader calls Rails.root.join whenever Rails is defined.
  def load_configuration
    return ::Noiseless.load_configuration! unless defined?(::Rails.root) && ::Rails.root.nil?
    ::Rails.stub(:root, Pathname(Dir.tmpdir)) { ::Noiseless.load_configuration! }
  end

  def test_yaml_connections_build_the_sqlite_adapter
    assert_instance_of ::Noiseless::Adapters::Sqlite, ::Noiseless.connections.client(:e2e_strict)
    assert_instance_of ::Noiseless::Adapters::Sqlite, ::Noiseless.connections.client(:e2e_lax)
  end

  def test_class_search_sync
    results = @posts.search_sync { |q| q.match(:title, "coffee").filter(:status, "published").sort(:_score, :desc) }
    assert_equal %w[1 3].sort, results.ids.sort
    assert_equal 2, results.total
    assert results.scores.all?(&:positive?)
  end

  def test_async_search_returns_a_task
    results = Sync { @posts.search { |q| q.range(:views, gte: 5) }.wait }
    assert_equal 3, results.total
  end

  def test_instance_chain_with_custom_methods_and_limit
    results = @posts.new.by_text("coffee").published.limit(1).execute_sync
    assert_equal 1, results.to_a.size
    assert_equal 2, results.total
  end

  def test_offset
    results = @posts.new.sort(:views, :desc).limit(2).offset(2).execute_sync
    assert_equal %w[2 4], results.ids
  end

  def test_concurrent_searches_in_one_reactor
    coffee, tea = Sync do
      tasks = [@posts.new.match(:title, "coffee").execute, @posts.new.match(:title, "tea").execute]
      tasks.map(&:wait)
    end
    assert_equal 2, coffee.total
    assert_equal 1, tea.total
  end

  def test_vector_and_hybrid
    vector = @posts.search_sync { |q| q.vector(:semantic, [1.0, 0.0, 0.4], k: 2) }
    assert_equal %w[1 3], vector.ids
    hybrid = @posts.search_sync { |q| q.hybrid("coffee", [1.0, 0.0, 0.4], field: :semantic, fields: %w[title body]) }
    assert_includes hybrid.ids, "3"
  end

  def test_unsupported_mode_follows_the_named_connection
    aggregate = ->(q) { q.filter(:status, "published").aggregation(:by_status, :terms, field: :status) }
    assert_raises(::Noiseless::SearchError) { @posts.search_sync(&aggregate) }
    assert_equal 3, @posts.search_sync(connection: :e2e_lax, &aggregate).total
  end

  def test_client_writes_are_noops_and_scope_callbacks_keep_search_current
    client = ::Noiseless.connections.client(:e2e_strict)
    post = @model.create!(title: "Iced coffee", body: "cold", status: "published", views: 3)
    Sync { client.index_document(index: "posts", id: post.id, document: post.attributes).wait }
    assert Sync { client.document_exists?(index: "posts", id: post.id).wait }
    assert_equal [post.id.to_s], @posts.search_sync { |q| q.match(:title, "iced") }.ids
  end
end
