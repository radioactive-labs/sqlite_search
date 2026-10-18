# frozen_string_literal: true

module SqliteSearch
  module NoiselessAdapter
    # Elasticsearch-shaped search response, the format Noiseless::ResponseFactory reads.
    module Response
      module_function

      def build(records, model:, total:, scorer:, score_columns:, started:)
        hits = records.map do |record|
          {
            "_index" => model.table_name,
            "_id" => record.id.to_s,
            "_score" => scorer.call(record),
            "_source" => record.as_json(root: false, except: score_columns)
          }
        end
        envelope(hits, total, started)
      end

      def empty(started:) = envelope([], 0, started)

      def envelope(hits, total, started)
        {
          "took" => ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round,
          "timed_out" => false,
          "_shards" => {"total" => 1, "successful" => 1, "skipped" => 0, "failed" => 0},
          "hits" => {
            "total" => {"value" => total, "relation" => "eq"},
            "max_score" => hits.map { |hit| hit["_score"] }.max,
            "hits" => hits
          }
        }
      end
    end
  end
end
