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
    # reordered by the reranker (RRF scores preserved), or the input unchanged
    # on any reranker failure.
    def rerank(query, fused, model:, scope_name:, reranker:)
      return fused unless reranker
      ids = fused.map(&:first)
      by_id = model.where(model.primary_key => ids).index_by { |r| r.public_send(model.primary_key) }
      records = ids.filter_map { |id| by_id[id] }
      scores = fused.to_h
      begin
        reordered = reranker.call(query, records, model: model, scope: scope_name)
        reordered.filter_map do |rec|
          id = rec.public_send(model.primary_key)
          [id, scores[id]] if scores.key?(id)
        end
      rescue => e
        ActiveRecord::Base.logger&.warn { "sqlite_search: rerank failed, using fused order (#{e.class}: #{e.message})" }
        fused
      end
    end
  end
end
