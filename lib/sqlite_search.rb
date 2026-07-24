# frozen_string_literal: true

require "active_record"
require "sqlite_search/version"
require "sqlite_search/query"
require "sqlite_search/fts5"
require "sqlite_search/migration"

module SqliteSearch
end

require "sqlite_search/railtie" if defined?(Rails::Railtie)
