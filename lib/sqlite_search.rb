# frozen_string_literal: true

require "active_record"
require "sqlite_search/version"
require "sqlite_search/errors"
require "sqlite_search/sql"
require "sqlite_search/scored_relation"
require "sqlite_search/config"
require "sqlite_search/vec"
require "sqlite_search/vec/definition"
require "sqlite_search/vec/backend"
require "sqlite_search/hybrid"
require "sqlite_search/embed_job"
require "sqlite_search/query"
require "sqlite_search/fts5"
require "sqlite_search/migration"
require "sqlite_search/fts5/definition"
require "sqlite_search/fts5/backend"
require "sqlite_search/model"

module SqliteSearch
end

require "sqlite_search/railtie" if defined?(Rails::Railtie)
