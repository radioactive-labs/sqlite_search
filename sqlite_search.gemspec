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

  spec.add_dependency "activerecord", ">= 7.1"
  spec.add_development_dependency "sqlite3", ">= 2.1"
  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "railties", ">= 7.1"
end
