# frozen_string_literal: true
require "test_helper"

class VersionTest < SqliteSearch::TestCase
  def test_version_is_defined
    assert_match(/\A\d+\.\d+\.\d+\z/, SqliteSearch::VERSION)
  end
end
