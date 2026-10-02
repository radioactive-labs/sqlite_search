# frozen_string_literal: true

require "test_helper"

class SecondaryRecord < ActiveRecord::Base
  self.abstract_class = true
  establish_connection(adapter: "sqlite3", database: ":memory:")
end

class VecMultiDbTest < SqliteSearch::TestCase
  def setup
    SecondaryRecord.with_connection do |conn|
      conn.create_table(:notes, force: true) { |t| t.text :body }
      conn.create_virtual_table("notes_semantic_vec", "vec0", ["id integer primary key", "embedding float[3] distance_metric=cosine"])
    end
    @klass = Class.new(SecondaryRecord) do
      self.table_name = "notes"
      include SqliteSearch::Model

      vec_scope :semantic, against: :body, dimensions: 3, sync: :inline
    end
  end

  def teardown
    SecondaryRecord.with_connection do |conn|
      %w[notes_semantic_vec notes].each { |t| conn.execute("DROP TABLE IF EXISTS #{conn.quote_table_name(t)}") }
    end
  end

  def test_vectors_live_in_the_models_database
    @klass.create!(id: 1, body: "coffee")
    assert_equal [1], @klass.semantic("coffee").pluck(:id)
  end
end
