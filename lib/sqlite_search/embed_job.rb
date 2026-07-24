# frozen_string_literal: true

if defined?(ActiveJob)
  module SqliteSearch
    class EmbedJob < ActiveJob::Base
      def perform(model_name, id, scope_name)
        klass = model_name.constantize
        record = klass.find_by(klass.primary_key => id)
        return unless record # deleted before the job ran
        definition = klass.sqlite_search_vec_definitions.fetch(scope_name.to_sym)
        SqliteSearch::Vec::Backend.new(definition).embed_and_store(record)
      end
    end
  end
end
