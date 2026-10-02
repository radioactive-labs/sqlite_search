# frozen_string_literal: true

require_relative "lib/sqlite_search/version"

Gem::Specification.new do |spec|
  spec.name = "sqlite_search"
  spec.version = SqliteSearch::VERSION
  spec.authors = ["Radioactive Labs"]
  spec.email = ["sfroelich01@gmail.com"]
  spec.homepage = "https://github.com/radioactive-labs/sqlite_search"
  spec.summary = "Full-text, vector, and hybrid search for ActiveRecord, without leaving SQLite."
  spec.description = <<~DESC.tr("\n", " ").strip
    Full-text, vector, and hybrid search for ActiveRecord, without leaving SQLite.
    sqlite_search gives a model full-text search (FTS5 with BM25 ranking), vector
    search (sqlite-vec through the neighbor gem, with your app supplying
    embeddings), and hybrid search that fuses the two with Reciprocal Rank Fusion
    and an optional reranking step, all behind one declarative DSL. No search
    cluster to run, no separate copy of your data, no database triggers, and a
    schema that restores cleanly from schema.rb.
  DESC
  spec.license = "MIT"
  # Ruby 3.3 is the floor: vector and hybrid search run on neighbor 1.x,
  # which requires Ruby 3.3.
  spec.required_ruby_version = ">= 3.3"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["documentation_uri"] = "#{spec.homepage}#readme"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["lib/**/*", "README.md", "CHANGELOG.md", "MIT-LICENSE"]
  spec.require_paths = ["lib"]

  # ActiveRecord 8.0 is the floor: create_virtual_table (used by the FTS5
  # migration helper and its schema.rb round-trip) was added in Rails 8.0.
  # Verified: fails on 7.1/7.2 (no create_virtual_table), passes on 8.0/8.1.
  spec.add_dependency "activerecord", ">= 8.0"

  spec.add_development_dependency "sqlite3", ">= 2.1"
  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "railties", ">= 8.0"
  spec.add_development_dependency "neighbor", "~> 1.2"
  spec.add_development_dependency "sqlite-vec"
  spec.add_development_dependency "activejob", ">= 8.0"
  spec.add_development_dependency "standard", "~> 1.3"
end
