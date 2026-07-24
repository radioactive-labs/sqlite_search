# frozen_string_literal: true

module SqliteSearch
  class Configuration
    # embedder: block |text, model:, scope:| -> Array<Float>
    # job_queue: the ActiveJob queue name EmbedJob is enqueued to (default: :default)
    # reranker: block |query, documents, model:, scope:| -> reordered documents
    attr_accessor :embedder, :job_queue, :reranker
  end

  def self.config
    @config ||= Configuration.new
  end

  # Register the app's embedder: a block |text, model:, scope:| -> Array<Float>.
  def self.embedder(&block)
    config.embedder = block
  end

  # Register the app's reranker: |query, documents, model:, scope:| -> reordered documents.
  def self.reranker(&block)
    config.reranker = block
  end
end
