# frozen_string_literal: true

module SqliteSearch
  # Lazily define SqliteSearch::EmbedJob the first time async vec sync is used.
  # const_set gives the ActiveJob subclass a real name so it can be enqueued.
  def self.ensure_embed_job!
    return const_get(:EmbedJob) if const_defined?(:EmbedJob, false)
    begin
      require "active_job"
    rescue LoadError
      raise SqliteSearch::Error,
        "Async vector indexing needs ActiveJob. Add `activejob` to your Gemfile, " \
        "or declare the scope with `vec_scope ..., sync: :inline`."
    end
    job = Class.new(ActiveJob::Base) do
      # Evaluated at enqueue time, so it picks up config set after the job is
      # defined. Falls back to ActiveJob's :default queue when unconfigured.
      queue_as { SqliteSearch.config.job_queue || :default }

      def perform(model_name, id, scope_name)
        klass = model_name.constantize
        record = klass.find_by(klass.primary_key => id)
        return unless record # deleted before the job ran
        definition = klass.sqlite_search_vec_definitions.fetch(scope_name.to_sym)
        SqliteSearch::Vec::Backend.new(definition).embed_and_store(record)
      end
    end
    const_set(:EmbedJob, job)
  end
end
