# frozen_string_literal: true

module SqliteSearch
  class Configuration
    attr_accessor :embedder
  end

  def self.config
    @config ||= Configuration.new
  end

  # Register the app's embedder: a block |text, model:, scope:| -> Array<Float>.
  def self.embedder(&block)
    config.embedder = block
  end
end
