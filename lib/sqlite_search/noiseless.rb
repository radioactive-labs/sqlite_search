# frozen_string_literal: true

# Opt-in noiseless integration: `require "sqlite_search/noiseless"` defines
# Noiseless::Adapters::Sqlite, which `adapter: sqlite` in config/noiseless.yml
# resolves to. Not loaded by `require "sqlite_search"`.
require "noiseless"
require "sqlite_search"
require "sqlite_search/noiseless_adapter/unsupported"
require "sqlite_search/noiseless_adapter/response"
require "sqlite_search/noiseless_adapter/text_options"
require "sqlite_search/noiseless_adapter/translator"
require "sqlite_search/noiseless_adapter/sqlite"
