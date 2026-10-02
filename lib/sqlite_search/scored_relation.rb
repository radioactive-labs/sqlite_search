# frozen_string_literal: true

module SqliteSearch
  # Extended onto relations that select a computed column (rank, distance,
  # score) alongside table.*. A bare #count would wrap that whole select list
  # in COUNT(...), which is invalid SQL, so count rows instead.
  module ScoredRelation
    def count(column_name = (:all unless block_given?), &) = super
  end
end
