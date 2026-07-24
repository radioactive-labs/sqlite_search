# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module SqliteSearch
  module Generators
    class VecGenerator < Rails::Generators::NamedBase
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      class_option :index, type: :string, default: "semantic", desc: "Index/scope name (default: semantic)"
      class_option :dimensions, type: :numeric, required: true, desc: "Embedding dimensions (e.g. 768)"

      def create_migration_file
        migration_template "create_vec_index.rb.tt", "db/migrate/create_#{index_name}_vec.rb"
      end

      private

      def table_name = name.tableize
      def index_name = options[:index]
      def dimensions = options[:dimensions].to_i
      def migration_class_suffix = "#{index_name.camelize}Vec"
      def migration_version = "#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}"
    end
  end
end
