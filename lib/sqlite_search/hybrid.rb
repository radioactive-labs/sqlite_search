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
  end
end
