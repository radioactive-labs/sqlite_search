# frozen_string_literal: true
require "test_helper"
require "rails/generators"
require "generators/sqlite_search/fts5_generator"
require "tmpdir"

class GeneratorTest < SqliteSearch::TestCase
  def test_renders_migration_with_weights_and_default_index_name
    Dir.mktmpdir do |dir|
      SqliteSearch::Generators::Fts5Generator.start(
        ["Post", "title", "body", "--weights", "2,1"], destination_root: dir
      )
      file = Dir[File.join(dir, "db/migrate/*_create_search_fts5.rb")].first
      refute_nil file, "migration file should be generated"
      content = File.read(file)
      # default index name is "search" -> table posts_search_fts (not posts_post_search_fts)
      assert_match(/create_fts5_table :posts, :search, against: \{ title: 2, body: 1 \}/, content)
    end
  end

  def test_index_option_overrides_the_index_name
    Dir.mktmpdir do |dir|
      SqliteSearch::Generators::Fts5Generator.start(
        ["Post", "body", "--index", "by_body"], destination_root: dir
      )
      file = Dir[File.join(dir, "db/migrate/*_create_by_body_fts5.rb")].first
      refute_nil file, "migration file should be generated with the custom index name"
      content = File.read(file)
      assert_match(/create_fts5_table :posts, :by_body, against: :body/, content)
    end
  end

  def test_mismatched_weights_count_raises
    Dir.mktmpdir do |dir|
      # Thor::Error is rescued and merely printed by Thor::Base::ClassMethods#start
      # unless config[:debug] is set (or THOR_DEBUG=1), in which case it re-raises.
      assert_raises(Thor::Error) do
        SqliteSearch::Generators::Fts5Generator.start(
          ["Post", "title", "body", "summary", "--weights", "2,1"], destination_root: dir, debug: true
        )
      end
    end
  end
end

class RailtieLoadTest < SqliteSearch::TestCase
  def test_railtie_defines_class
    require "rails"
    require "sqlite_search/railtie"
    assert defined?(SqliteSearch::Railtie)
  end
end
