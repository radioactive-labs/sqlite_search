# frozen_string_literal: true

require "rails/railtie"

module SqliteSearch
  class Railtie < Rails::Railtie
    initializer "sqlite_search.active_record" do
      ActiveSupport.on_load(:active_record) do
        require "sqlite_search/model"
        include SqliteSearch::Model
      end
      ActiveSupport.on_load(:active_record) do
        require "sqlite_search/migration"
        ActiveRecord::Migration.include(SqliteSearch::Migration)
      end
    end

    # Define EmbedJob as soon as ActiveJob loads, not when the first model with
    # a vec_scope loads: a worker process deserializes the job by class name,
    # possibly before any model has been loaded.
    initializer "sqlite_search.active_job" do
      ActiveSupport.on_load(:active_job) { SqliteSearch.ensure_embed_job! }
    end

    rake_tasks do
      load File.expand_path("../tasks/sqlite_search.rake", __dir__)
    end
  end
end
