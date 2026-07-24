# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test" << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
end

# `rake standard` / `rake standard:fix` when the linter is bundled (dev + CI).
require "standard/rake" if Gem.loaded_specs.key?("standard")

task default: :test
