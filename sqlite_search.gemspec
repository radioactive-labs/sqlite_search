# frozen_string_literal: true

require_relative "lib/sqlite_search/version"

Gem::Specification.new do |spec|
  spec.name = "sqlite_search"
  spec.version = SqliteSearch::VERSION
  spec.authors = ["Radioactive Labs"]
  spec.summary = "Full-text (FTS5), vector, and hybrid search for ActiveRecord on SQLite."
  spec.homepage = "https://github.com/radioactive-labs/sqlite_search"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.files = Dir["lib/**/*", "README.md"]
  spec.require_paths = ["lib"]

  # ActiveRecord 8.0 is the floor: create_virtual_table (used by the FTS5
  # migration helper and its schema.rb round-trip) was added in Rails 8.0.
  # Verified: fails on 7.1/7.2 (no create_virtual_table), passes on 8.0/8.1.
  spec.add_dependency "activerecord", ">= 8.0"
  spec.add_development_dependency "sqlite3", ">= 2.1"
  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "railties", ">= 8.0"
end
