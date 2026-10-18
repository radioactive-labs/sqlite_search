# frozen_string_literal: true

module SqliteSearch
  module Hybrid
    module_function

    # Weighted Reciprocal Rank Fusion of two id lists (each already in rank
    # order): score = w_a / (k + rank_a) + w_b / (k + rank_b), ranks 1-based,
    # an absent id contributing 0. A zero-weight list is left out entirely.
    # Returns [[id, score], ...] by score desc; ties keep first appearance
    # (list a, then list b).
    def rrf(ids_a, ids_b, k: 60, weights: [1.0, 1.0])
      raise SqliteSearch::Error, "RRF takes 2 weights, got #{weights.inspect}." unless weights.size == 2
      weights = weights.map { |weight| Float(weight) }
      if weights.any? { |weight| !weight.finite? || weight.negative? } || weights.all?(&:zero?)
        raise SqliteSearch::Error, "RRF weights must be finite, non-negative, and not all zero, got #{weights.inspect}."
      end
      scores = Hash.new(0.0)
      [ids_a, ids_b].zip(weights).each do |ids, weight|
        next if weight.zero?
        ids.each_with_index { |id, index| scores[id] += weight / (k + index + 1) }
      end
      scores.each_with_index.sort_by { |(_, score), index| [-score, index] }.map(&:first)
    end

    # `relation` narrowed to the fused ids, in fused order, with each fused
    # score selected AS score_column. Rank and score come from Ruby, so they
    # are carried as SQL CASE expressions: the score becomes a real attribute
    # (works with pluck, first, etc.) and the fused order replaces any order
    # chained before.
    def relation(relation, fused, score_column)
      model = relation.klass
      ids = fused.map(&:first)
      model.with_connection do |conn|
        pk_sql = "#{model.quoted_table_name}.#{conn.quote_column_name(model.primary_key)}"
        relation.where(model.primary_key => ids)
          .reorder(Arel.sql(Sql.id_case(pk_sql, ids.each_with_index.to_h, conn)))
          .select("#{model.quoted_table_name}.*, #{Sql.id_case(pk_sql, fused.to_h, conn)} AS #{score_column}")
          .extending(ScoredRelation)
      end
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
