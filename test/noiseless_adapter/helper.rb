# frozen_string_literal: true

require "test_helper"

begin
  require "sqlite_search/noiseless"
rescue LoadError
  # noiseless needs Ruby 4.0+ and Rails 8.1+. These tests run in the
  # "noiseless adapter" CI job (BUNDLE_GEMFILE=gemfiles/noiseless.gemfile).
end

module SqliteSearch
  class NoiselessTestCase < TestCase
    TABLES = %w[posts_text_fts posts_titles_fts posts_semantic_vec posts_nearby_vec posts].freeze

    # Stub embedder (test_helper): [has "coffee", has "tea", length / 100].
    POSTS = [
      {id: 1, title: "Morning coffee", body: "a warm cup to start the day", status: "published", views: 10, tenant_id: 1},
      {id: 2, title: "Green tea", body: "a calm afternoon drink", status: "draft", views: 5, tenant_id: 1},
      {id: 3, title: "Coffee shop guide", body: "where to find good coffee and tea", status: "published", views: 20, tenant_id: 2},
      {id: 4, title: "100% juice_box", body: "orange", status: "published", views: 1, tenant_id: 2}
    ].freeze

    def setup
      skip "noiseless is not installed (BUNDLE_GEMFILE=gemfiles/noiseless.gemfile)" unless defined?(::Noiseless::Adapters::Sqlite)
      @conn = ActiveRecord::Base.connection
      @conn.create_table(:posts, force: true) do |t|
        t.string :title
        t.text :body
        t.string :status
        t.integer :views
        t.integer :tenant_id
      end
      @conn.create_virtual_table("posts_text_fts", "fts5", ["title", "body", "tokenize = 'porter unicode61'"])
      @conn.create_virtual_table("posts_titles_fts", "fts5", ["title", "tokenize = 'porter unicode61'"])
      @conn.create_virtual_table("posts_semantic_vec", "vec0", ["id integer primary key", "embedding float[3] distance_metric=cosine"])
      @conn.create_virtual_table("posts_nearby_vec", "vec0", ["id integer primary key", "embedding float[3] distance_metric=l2"])
      # Other suites rebuild posts with other columns; a cached prepared
      # statement (e.g. find) would keep the old column names.
      @conn.clear_cache!
      @model = Class.new(ActiveRecord::Base) do
        self.table_name = "posts"
        include SqliteSearch::Model

        fts5_scope :text, against: {title: 2.0, body: 1.0}
        fts5_scope :titles, against: :title
        vec_scope :semantic, against: [:title, :body], dimensions: 3, sync: :inline
        vec_scope :nearby, against: :title, dimensions: 3, distance: :euclidean, sync: :inline
      end
      POSTS.each { |attrs| @model.create!(attrs) }
      @search = Class.new(::Noiseless::Model) { index_name "posts" }
      @adapter = adapter
    end

    def teardown
      TABLES.each { |t| @conn.execute("DROP TABLE IF EXISTS #{@conn.quote_table_name(t)}") } if @conn
    end

    def adapter(**options)
      ::Noiseless::Adapters::Sqlite.new(**options).tap { |a| a.register_model(@model, index_name: "posts") }
    end

    # Builds a query with noiseless's own QueryBuilder and runs it on the
    # adapter, returning a Noiseless::Response::Results.
    def search(adapter = @adapter)
      builder = ::Noiseless::QueryBuilder.new(@search)
      yield builder
      Sync { adapter.search(builder.to_ast, model_class: @search).wait }
    end

    def capture_log
      io = StringIO.new
      original = ActiveRecord::Base.logger
      ActiveRecord::Base.logger = Logger.new(io)
      yield
      io.string
    ensure
      ActiveRecord::Base.logger = original
    end
  end
end
