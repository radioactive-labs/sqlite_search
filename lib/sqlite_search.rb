# frozen_string_literal: true

require "active_record"
require "sqlite_search/version"
require "sqlite_search/query"

module SqliteSearch
end

require "sqlite_search/railtie" if defined?(Rails::Railtie)
