# frozen_string_literal: true

require "test_helper"

class VecSyncTest < SqliteSearch::TestCase
  include ActiveJob::TestHelper

  def setup
    @conn = ActiveRecord::Base.connection
    @conn.create_table(:posts, force: true) { |t|
      t.text :body
      t.string :title
    }
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

  def test_async_uses_configured_job_queue
    original = SqliteSearch.config.job_queue
    SqliteSearch.config.job_queue = :embeddings
    async_klass = Class.new(ActiveRecord::Base) do
      self.table_name = "posts"
      include SqliteSearch::Model

      vec_scope :semantic, against: :body, dimensions: 3
    end
    assert_enqueued_with(job: SqliteSearch::EmbedJob, queue: "embeddings") do
      async_klass.create!(id: 6, body: "coffee")
    end
  ensure
    SqliteSearch.config.job_queue = original
  end

  def test_dimension_mismatch_raises
    bad_klass = Class.new(ActiveRecord::Base) do
      self.table_name = "posts"
      include SqliteSearch::Model

      vec_scope :semantic, against: :body, dimensions: 5, sync: :inline # stub returns 3 dims
    end
    assert_raises(SqliteSearch::Error) { bad_klass.create!(id: 1, body: "coffee") }
  end

  def test_non_integer_primary_key_raises_on_sync
    @conn.create_table(:docs, id: false, force: true) { |t|
      t.string :uid, primary_key: true
      t.text :body
    }
    @conn.create_virtual_table("docs_semantic_vec", "vec0", ["id integer primary key", "embedding float[3] distance_metric=cosine"])
    k = Class.new(ActiveRecord::Base) do
      self.table_name = "docs"
      self.primary_key = "uid"
      include SqliteSearch::Model

      vec_scope :semantic, against: :body, dimensions: 3, sync: :inline
    end
    assert_raises(SqliteSearch::Error) { k.create!(uid: "abc", body: "coffee") }
  ensure
    %w[docs_semantic_vec docs].each { |t| @conn.execute("DROP TABLE IF EXISTS #{@conn.quote_table_name(t)}") }
  end

  def test_watched_change_from_an_earlier_save_in_the_transaction_reembeds
    k = inline_klass
    p = k.create!(id: 1, body: "coffee")
    before = @conn.select_value("SELECT vec_to_json(embedding) FROM posts_semantic_vec WHERE id = 1")
    k.transaction do
      p.update!(body: "green tea")
      p.update!(title: "renamed") # last save leaves only title in saved_changes
    end
    after = @conn.select_value("SELECT vec_to_json(embedding) FROM posts_semantic_vec WHERE id = 1")
    refute_equal before, after
  end

  def test_rolled_back_change_does_not_reembed_on_a_later_commit
    k = inline_klass
    p = k.create!(id: 1, body: "coffee")
    k.transaction do
      p.update!(body: "green tea")
      raise ActiveRecord::Rollback
    end
    p.reload
    @conn.execute("DELETE FROM posts_semantic_vec")
    p.update!(title: "renamed")
    assert_equal 0, vec_count
  end

  def test_embed_job_reaches_records_hidden_by_a_default_scope
    k = Class.new(ActiveRecord::Base) do
      self.table_name = "posts"
      include SqliteSearch::Model

      default_scope { where.not(title: "hidden") }
      vec_scope :semantic, against: :body, dimensions: 3, sync: :manual
    end
    Object.const_set(:HiddenEmbedPost, k)
    SqliteSearch.ensure_embed_job! # sync: :manual never defines it
    k.unscoped.create!(id: 1, body: "coffee", title: "hidden")
    SqliteSearch::EmbedJob.perform_now("HiddenEmbedPost", 1, "semantic")
    assert_equal 1, vec_count
  ensure
    Object.send(:remove_const, :HiddenEmbedPost) if Object.const_defined?(:HiddenEmbedPost)
  end
end
