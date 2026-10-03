# frozen_string_literal: true

require "test_helper"

class Fts5SourceTest < SqliteSearch::TestCase
  def setup
    @conn = ActiveRecord::Base.connection
    @conn.create_table(:docs, force: true) { |t|
      t.text :body
      t.json :metadata
      t.integer :views
    }
    @conn.create_virtual_table("docs_keyword_fts", :fts5, ["text", "tags"])
    @klass = Class.new(ActiveRecord::Base) do
      self.table_name = "docs"
      include SqliteSearch::Model

      fts5_scope :keyword, against: {text: 1.0, tags: 2.0}, source: :search_document, watch: [:body, :metadata]

      def search_document
        {text: body.to_s.upcase, tags: Array(metadata&.dig("tags")).join(" ")}
      end
    end
  end

  def teardown
    %w[docs_keyword_fts docs].each { |t| @conn.execute("DROP TABLE IF EXISTS #{@conn.quote_table_name(t)}") }
  end

  def indexed(column) = @conn.select_values("SELECT #{column} FROM docs_keyword_fts")

  def test_indexes_the_source_document
    @klass.create!(body: "coffee", metadata: {"tags" => ["drinks"]})
    assert_equal ["COFFEE"], indexed(:text)
    assert_equal ["drinks"], indexed(:tags)
    assert_equal 1, @klass.keyword("drinks").count
  end

  def test_change_to_a_watched_column_resyncs
    doc = @klass.create!(body: "coffee", metadata: {"tags" => ["drinks"]})
    doc.update!(metadata: {"tags" => ["breakfast"]})
    assert_equal ["breakfast"], indexed(:tags)
  end

  def test_change_to_an_unwatched_column_does_not_resync
    doc = @klass.create!(body: "coffee", metadata: {})
    @conn.execute("DELETE FROM docs_keyword_fts")
    doc.update!(views: 5)
    assert_empty indexed(:text)
  end

  def test_reindex_rebuilds_from_the_source
    @klass.insert_all([{id: 1, body: "tea", metadata: {"tags" => ["green"]}}])
    @klass.reindex(:keyword)
    assert_equal ["TEA"], indexed(:text)
    assert_equal [1], @klass.keyword("green").pluck(:id)
  end

  def test_source_without_watch_raises
    assert_raises(SqliteSearch::Error) do
      Class.new(ActiveRecord::Base) do
        self.table_name = "docs"
        include SqliteSearch::Model

        fts5_scope :keyword, against: {text: 1.0, tags: 2.0}, source: :search_document
      end
    end
  end
end
