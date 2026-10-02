# frozen_string_literal: true

module SqliteSearch
  module Fts5
    module_function

    # against: :body | [:title, :body] | { title: 2.0, body: 1.0 }
    def columns_for(against)
      case against
      when Hash then against.keys.map(&:to_sym)
      when Array then against.map(&:to_sym)
      else [against.to_sym]
      end
    end

    def weights_for(against)
      against.is_a?(Hash) ? against.values.map(&:to_f) : nil
    end

    # Extended onto the .none relation returned for blank queries so that
    # .order_by_rank chains safely (returns the same empty relation).
    module NullRank
      def order_by_rank(threshold: nil) = self
    end
  end
end
