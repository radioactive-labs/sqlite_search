# frozen_string_literal: true
require "test_helper"
require "active_job"

class VecSyncTest < SqliteSearch::TestCase
  include ActiveJob::TestHelper

  def setup
    ActiveJob::Base.queue_adapter = :test
    @conn = ActiveRecord::Base.connection
    @conn.create_table(:posts, force: true) { |t| t.text :body; t.string :title }
    @conn.create_virtual_table("posts_semantic_vec", "vec0", ["id integer primary key", "embedding float[3] distance_metric=cosine"])
  end

  def teardown
    clear_enqueued_jobs
    %w[posts_semantic_vec posts].each { |t| @conn.execute("DROP TABLE IF EXISTS #{@conn.quote_table_name(t)}") }
  end

  def inline_klass
    Class.new(ActiveRecord::Base) do
      self.table_name = "posts"
      include SqliteSearch::Model
      vec_scope :semantic, against: :body, dimensions: 3, sync: :inline
    end
  end

  def vec_count = @conn.select_value("SELECT count(*) FROM posts_semantic_vec").to_i

  def test_inline_sync_stores_vector_on_create
    inline_klass.create!(id: 1, body: "coffee")
    assert_equal 1, vec_count
  end

  def test_inline_sync_updates_vector
    k = inline_klass
    p = k.create!(id: 1, body: "coffee")
    p.update!(body: "green tea")
    assert_equal 1, vec_count # still one row, re-embedded
  end

  def test_inline_sync_removes_on_destroy
    k = inline_klass
    p = k.create!(id: 1, body: "coffee")
    p.destroy!
    assert_equal 0, vec_count
  end

  def test_blank_against_removes_vector
    k = inline_klass
    p = k.create!(id: 1, body: "coffee")
    assert_equal 1, vec_count
    p.update!(body: "")
    assert_equal 0, vec_count
  end

  def test_non_indexed_column_change_ignored
    k = inline_klass
    p = k.create!(id: 1, body: "coffee")
    p.update!(title: "changed")
    assert_equal 1, vec_count # unchanged, no error
  end

  def test_async_enqueues_embed_job
    async_klass = Class.new(ActiveRecord::Base) do
      self.table_name = "posts"
      include SqliteSearch::Model
      vec_scope :semantic, against: :body, dimensions: 3 # default :async
    end
    assert_enqueued_with(job: SqliteSearch::EmbedJob) do
      async_klass.create!(id: 5, body: "coffee")
    end
  end
end
