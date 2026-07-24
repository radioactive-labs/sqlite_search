# frozen_string_literal: true
require "test_helper"

class ModelScopeTest < SqliteSearch::TestCase
  def setup
    conn = ActiveRecord::Base.connection
    conn.create_table(:posts, force: true) { |t| t.string :title; t.text :body }
    conn.create_virtual_table("posts_by_body_fts", :fts5, ["body", "tokenize = 'porter unicode61'"])

    @post_class = Class.new(ActiveRecord::Base) do
      self.table_name = "posts"
      include SqliteSearch::Model
      fts5_scope :by_body, against: :body
    end
    # index two rows by hand (sync comes in Task 4)
    conn.execute("INSERT INTO posts (id, body) VALUES (1, 'morning coffee'), (2, 'evening tea')")
    conn.execute("INSERT INTO posts_by_body_fts (rowid, body) VALUES (1, 'morning coffee'), (2, 'evening tea')")
  end

  def teardown
    conn = ActiveRecord::Base.connection
    %w[posts_by_body_fts posts].each { |t| conn.execute("DROP TABLE IF EXISTS #{conn.quote_table_name(t)}") }
  end

  def test_scope_filters_by_match
    ids = @post_class.by_body("coffee").pluck(:id)
    assert_equal [1], ids
  end

  def test_stems_via_porter_tokenizer
    assert_equal [2], @post_class.by_body("teas").pluck(:id) # porter stems teas -> tea
  end

  def test_blank_query_returns_none
    assert_equal [], @post_class.by_body("").pluck(:id)
  end

  def test_composes_with_other_conditions
    rel = @post_class.by_body("coffee").where("id > 0").order(id: :desc)
    assert_kind_of ActiveRecord::Relation, rel
    assert_equal [1], rel.pluck(:id)
  end
end
