source "https://rubygems.org"
gemspec

# CI pins a specific ActiveRecord line via RAILS_VERSION (e.g. "8.0", "8.1").
# Unset locally, so development resolves the latest supported version.
if (rails_version = ENV["RAILS_VERSION"])
  gem "activerecord", "~> #{rails_version}.0"
  gem "railties", "~> #{rails_version}.0"
end
