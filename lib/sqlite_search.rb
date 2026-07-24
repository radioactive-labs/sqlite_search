# frozen_string_literal: true

require "active_record"
require "sqlite_search/version"
require "sqlite_search/query"
require "sqlite_search/fts5"
require "sqlite_search/migration"
require "sqlite_search/fts5/definition"
require "sqlite_search/fts5/backend"
require "sqlite_search/model"

module SqliteSearch
end

require "sqlite_search/railtie" if defined?(Rails::Railtie)
