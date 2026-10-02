# frozen_string_literal: true

require "test_helper"

class VecSourceTest < SqliteSearch::TestCase
  include ActiveJob::TestHelper

  def setup
    @conn = ActiveRecord::Base.connection
    @conn.create_table(:docs, force: true) { |t|
      t.text :body
      t.json :metadata
      t.integer :views
    }
    @conn.create_virtual_table("docs_semantic_vec", "vec0", ["id integer primary key", "embedding float[3] distance_metric=cosine"])
    @embedded = embedded = []
    @embedder = ->(text, **) {
      embedded << text
      [text.include?("coffee") ? 1.0 : 0.0, 0.0, 0.1]
    }
  end

  def teardown
    clear_enqueued_jobs
    %w[docs_semantic_vec docs].each { |t| @conn.execute("DROP TABLE IF EXISTS #{@conn.quote_table_name(t)}") }
  end

  def vec_count = @conn.select_value("SELECT count(*) FROM docs_semantic_vec").to_i

  def model(**options)
    embedder = @embedder
    Class.new(ActiveRecord::Base) do
      self.table_name = "docs"
      include SqliteSearch::Model

      vec_scope :semantic, dimensions: 3, embedder: embedder, **options

      def embedding_text = "#{metadata&.dig("summary")}\n#{body}"
    end
  end

  def test_embeds_the_source_text
    klass = model(source: :embedding_text, watch: [:body, :metadata], sync: :inline)
    klass.create!(body: "coffee", metadata: {"summary" => "drinks"})
    assert_equal ["drinks\ncoffee"], @embedded
  end

  def test_change_to_a_watched_column_re_embeds
    klass = model(source: :embedding_text, watch: [:body, :metadata], sync: :inline)
    doc = klass.create!(body: "coffee", metadata: {})
    doc.update!(metadata: {"summary" => "hot"})
    doc.update!(views: 3)
    assert_equal ["\ncoffee", "hot\ncoffee"], @embedded
  end

  def test_source_requires_watch
    assert_raises(SqliteSearch::Error) { model(source: :embedding_text) }
  end

  def test_manual_sync_with_source_needs_no_watch
    klass = model(source: :embedding_text, sync: :manual)
    doc = klass.create!(body: "coffee")
    doc.reembed(:semantic)
    assert_equal ["\ncoffee"], @embedded
  end

  def test_requires_exactly_one_of_against_and_source
    assert_raises(SqliteSearch::Error) { model }
    assert_raises(SqliteSearch::Error) { model(against: :body, source: :embedding_text, watch: [:body]) }
  end

  def test_rejects_an_unknown_sync_mode
    assert_raises(SqliteSearch::Error) { model(against: :body, sync: :later) }
  end

  def test_manual_sync_does_not_embed_on_save
    klass = model(against: :body, sync: :manual)
    klass.create!(body: "coffee")
    assert_empty @embedded
    assert_equal 0, vec_count
    assert_no_enqueued_jobs
  end

  def test_record_reembed_embeds_one_record
    klass = model(against: :body, sync: :manual)
    doc = klass.create!(body: "coffee")
    doc.reembed(:semantic)
    assert_equal 1, vec_count
    assert_equal [doc.id], klass.semantic("coffee").pluck(:id)
  end

  def test_manual_sync_still_removes_on_destroy
    klass = model(against: :body, sync: :manual)
    doc = klass.create!(body: "coffee")
    doc.reembed
    doc.destroy!
    assert_equal 0, vec_count
  end
end
