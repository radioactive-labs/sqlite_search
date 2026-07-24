# frozen_string_literal: true

namespace :sqlite_search do
  desc "Rebuild FTS5 index. Usage: rake sqlite_search:reindex[Post,by_body] (scope optional)"
  task :reindex, [:model, :scope] => :environment do |_t, args|
    raise ArgumentError, "model is required" unless args[:model]
    klass = args[:model].constantize
    klass.reindex(args[:scope])
    puts "Reindexed #{klass}#{args[:scope] ? " (#{args[:scope]})" : ""}."
  end
end
