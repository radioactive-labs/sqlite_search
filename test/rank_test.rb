# frozen_string_literal: true
require "test_helper"

class RankTest < SqliteSearch::TestCase
  def setup
    @conn = ActiveRecord::Base.connection
    @conn.create_table(:posts, force: true) { |t| t.string :title; t.text :body }
    @conn.create_virtual_table("posts_full_fts", :fts5, ["title", "body", "tokenize = 'porter unicode61'"])
    @klass = Class.new(ActiveRecord::Base) do
      self.table_name = "posts"
      include SqliteSearch::Model
      fts5_scope :full, against: { title: 2.0, body: 1.0 }
    end
    # match in body only (row 1) vs match in the higher-weighted title (row 2)
    @klass.create!(id: 1, title: "misc", body: "coffee coffee")
    @klass.create!(id: 2, title: "coffee", body: "misc")
  end

  def teardown
    %w[posts_full_fts posts].each { |t| @conn.execute("DROP TABLE IF EXISTS #{@conn.quote_table_name(t)}") }
  end

  def test_orders_by_relevance
    ids = @klass.full("coffee").order_by_rank.pluck(:id)
    assert_equal [2, 1], ids # title weight 2.0 wins
  end

  def test_exposes_rank_reader_higher_is_better
    top = @klass.full("coffee").order_by_rank.first
    assert_respond_to top, :full_rank
    assert_operator top.full_rank, :>, 0
  end

  def test_order_by_rank_safe_on_blank
    assert_equal [], @klass.full("").order_by_rank.to_a
  end
end
