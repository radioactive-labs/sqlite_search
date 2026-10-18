# frozen_string_literal: true

require "test_helper"

class DefinitionLookupTest < SqliteSearch::TestCase
  def setup
    ActiveRecord::Base.connection.create_table(:posts, force: true) { |t|
      t.string :title
      t.text :body
    }
    @klass = Class.new(ActiveRecord::Base) do
      self.table_name = "posts"
      include SqliteSearch::Model

      fts5_scope :full, against: {title: 2.0, body: 1.0}
      fts5_scope :titles, against: :title
      fts5_scope :also_titles, against: [:title]
      vec_scope :semantic, against: :body, dimensions: 3, sync: :manual
    end
  end

  def teardown
    ActiveRecord::Base.connection.drop_table(:posts, if_exists: true)
  end

  def test_fts5_for_prefers_fewest_columns_then_declaration_order
    assert_equal :titles, @klass.sqlite_search_fts5_for([:title]).name
  end

  def test_fts5_for_needs_every_field_covered
    assert_equal :full, @klass.sqlite_search_fts5_for(%w[title body]).name
    assert_nil @klass.sqlite_search_fts5_for(%w[title summary])
  end

  def test_vec_for_matches_scope_name
    assert_equal :semantic, @klass.sqlite_search_vec_for("semantic").name
    assert_nil @klass.sqlite_search_vec_for(:nope)
  end
end
