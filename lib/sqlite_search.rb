# frozen_string_literal: true

require "active_record"
require "sqlite_search/version"

module SqliteSearch
end

require "sqlite_search/railtie" if defined?(Rails::Railtie)
