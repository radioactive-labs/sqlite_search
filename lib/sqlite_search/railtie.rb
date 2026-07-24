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

    rake_tasks do
      load File.expand_path("../tasks/sqlite_search.rake", __dir__)
    end
  end
end
