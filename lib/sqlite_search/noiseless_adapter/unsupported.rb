# frozen_string_literal: true

module SqliteSearch
  module NoiselessAdapter
    # Raised during translation when the query can match nothing, so the
    # adapter answers with an empty response. Translation never continues with
    # a .none relation: the vec scope rebuilds its pre-filter from
    # all.only(:where, :joins), which drops none and would widen the search.
    class NoHits < StandardError; end

    # Per-query policy for AST features SQLite cannot honor. :strict raises.
    # :lax answers a narrowing feature (one whose omission would widen the
    # results) with no hits, and skips a decorative one, recording it so the
    # adapter can log what it ignored.
    class Unsupported
      MODES = %i[strict lax].freeze

      def self.mode(value)
        mode = value.to_s.to_sym
        return mode if MODES.include?(mode)
        raise ArgumentError, "unsupported: must be strict or lax, got #{value.inspect}"
      end

      attr_reader :skipped

      def initialize(mode)
        @mode = mode
        @skipped = []
      end

      def narrowing!(what)
        refuse!(what, "answer with no hits")
        raise NoHits
      end

      def decorative(what)
        refuse!(what, "skip it")
        @skipped << what
      end

      private

      def refuse!(what, lax_behavior)
        return if @mode == :lax
        raise Noiseless::SearchError, "the sqlite adapter does not support #{what} (set unsupported: lax on the connection to #{lax_behavior})"
      end
    end
  end
end
