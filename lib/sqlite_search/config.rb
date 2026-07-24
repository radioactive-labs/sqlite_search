# frozen_string_literal: true

module SqliteSearch
  class Configuration
    # embedder: block |text, model:, scope:| -> Array<Float>
    # job_queue: the ActiveJob queue name EmbedJob is enqueued to (default: :default)
    attr_accessor :embedder, :job_queue
  end

  def self.config
    @config ||= Configuration.new
  end

  # Register the app's embedder: a block |text, model:, scope:| -> Array<Float>.
  def self.embedder(&block)
    config.embedder = block
  end
end
