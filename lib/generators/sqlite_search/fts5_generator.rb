# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module SqliteSearch
  module Generators
    class Fts5Generator < Rails::Generators::NamedBase
      include ActiveRecord::Generators::Migration
      source_root File.expand_path("templates", __dir__)

      argument :columns, type: :array, default: [], banner: "column column"
      class_option :weights, type: :string, default: nil, desc: "Comma-separated BM25 weights aligned to columns"
      class_option :index, type: :string, default: nil,
        desc: "Index/scope name; the FTS table becomes <table>_<index>_fts (default: search)"

      def create_migration_file
        if options[:weights]
          weights = options[:weights].split(",")
          if weights.length != columns.length
            raise Thor::Error,
              "--weights expects one weight per column (#{columns.length} columns, got #{weights.length})"
          end
        end

        migration_template "create_fts5_index.rb.tt", "db/migrate/create_#{index_name}_fts5.rb"
      end

      private

      def table_name = name.tableize

      def index_name
        options[:index] || "search"
      end

      def migration_class_suffix = "#{index_name.camelize}Fts5"

      def migration_version = "#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}"

      def against_literal
        if options[:weights]
          weights = options[:weights].split(",").map(&:strip)
          pairs = columns.zip(weights).map { |c, w| "#{c}: #{w}" }.join(", ")
          "{ #{pairs} }"
        elsif columns.one?
          ":#{columns.first}"
        else
          "[#{columns.map { |c| ":#{c}" }.join(", ")}]"
        end
      end
    end
  end
end
