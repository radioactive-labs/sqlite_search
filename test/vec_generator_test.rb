# frozen_string_literal: true

require "test_helper"
require "rails/generators"
require "generators/sqlite_search/vec_generator"
require "tmpdir"

class VecGeneratorTest < SqliteSearch::TestCase
  def test_renders_vec_migration
    Dir.mktmpdir do |dir|
      SqliteSearch::Generators::VecGenerator.start(
        ["Post", "--index", "semantic", "--dimensions", "768"], destination_root: dir
      )
      file = Dir[File.join(dir, "db/migrate/*_create_semantic_vec.rb")].first
      refute_nil file, "migration file should be generated"
      assert_match(/create_vec_index :posts, :semantic, dimensions: 768/, File.read(file))
    end
  end

  def test_default_index_name_is_semantic
    Dir.mktmpdir do |dir|
      SqliteSearch::Generators::VecGenerator.start(["Post", "--dimensions", "3"], destination_root: dir)
      file = Dir[File.join(dir, "db/migrate/*_create_semantic_vec.rb")].first
      refute_nil file
      assert_match(/create_vec_index :posts, :semantic, dimensions: 3/, File.read(file))
    end
  end
end
