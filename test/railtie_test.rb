# frozen_string_literal: true

require "test_helper"
require "open3"

class RailtieTest < SqliteSearch::TestCase
  # Boots a bare Rails app in a subprocess (no models loaded) and resolves the
  # job class the way a worker deserializing an EmbedJob would.
  def test_embed_job_is_defined_once_active_job_loads
    script = <<~SCRIPT
      require "rails"
      require "active_record/railtie"
      require "active_job/railtie"
      require "sqlite_search"
      class DummyApp < Rails::Application
        config.eager_load = false
        config.logger = Logger.new(nil)
        config.secret_key_base = "x"
      end
      DummyApp.initialize!
      ActiveJob::Base
      print "SqliteSearch::EmbedJob".constantize.superclass
    SCRIPT
    out, err, status = Open3.capture3(RbConfig.ruby, "-Ilib", "-e", script)
    assert status.success?, err
    assert_equal "ActiveJob::Base", out
  end
end
