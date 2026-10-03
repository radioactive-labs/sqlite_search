# frozen_string_literal: true

module SqliteSearch
  module Hybrid
    module_function

    # Reciprocal Rank Fusion of two id lists (each already in rank order).
    # Returns [[id, score], ...] sorted by fused score desc.
    def rrf(ids_a, ids_b, k: 60)
      require "neighbor"
      a = ids_a.map { |id| {id: id} }
      b = ids_b.map { |id| {id: id} }
      Neighbor::Reranking.rrf(a, b, k: k).map { |row| [row[:result][:id], row[:score]] }
    end

    # Best-effort rerank. `fused` is [[id, score], ...]; returns the same shape
    # in the reranker's order, or the input unchanged on any reranker failure.
    # The reranker returns records, or [record, score] pairs to replace each
    # record's RRF score with its own. Records outside `fused` and repeats are
    # dropped. Scoring only some records would mix two score scales in one
    # column, so it counts as a reranker failure.
    def rerank(query, fused, model:, scope_name:, reranker:)
      return fused unless reranker
      ids = fused.map(&:first)
      by_id = model.where(model.primary_key => ids).index_by { |r| r.public_send(model.primary_key) }
      records = ids.filter_map { |id| by_id[id] }
      scores = fused.to_h
      begin
        reordered = reranker.call(query, records, model: model, scope: scope_name).filter_map do |entry|
          rec, rerank_score = entry.is_a?(Array) ? entry : [entry, nil]
          id = rec.public_send(model.primary_key)
          [id, rerank_score] if scores.key?(id)
        end.uniq(&:first)
        scored = reordered.count { |(_, rerank_score)| rerank_score }
        unless scored.zero? || scored == reordered.size
          raise SqliteSearch::Error, "reranker scored #{scored} of #{reordered.size} records; return all records or all [record, score] pairs"
        end
        reordered.map { |id, rerank_score| [id, rerank_score || scores[id]] }
      rescue => e
        ActiveRecord::Base.logger&.warn { "sqlite_search: rerank failed, using fused order (#{e.class}: #{e.message})" }
        fused
      end
    end
  end
end
