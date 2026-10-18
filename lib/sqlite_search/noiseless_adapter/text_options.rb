# frozen_string_literal: true

module SqliteSearch
  module NoiselessAdapter
    # Maps Elasticsearch multi_match / combined_fields fields and options onto
    # sqlite_search's FTS5 query options. Defaults follow Elasticsearch: terms
    # are OR-ed unless operator: "and".
    class TextOptions
      TYPES = {
        "best_fields" => {}, "most_fields" => {}, "cross_fields" => {},
        "phrase" => {phrase: true},
        "phrase_prefix" => {phrase: true, prefix: true},
        "bool_prefix" => {prefix: true}
      }.freeze
      # Options that only shape Elasticsearch scoring or analysis.
      IGNORED = %i[boost tie_breaker analyzer auto_generate_synonyms_phrase_query lenient].freeze

      attr_reader :columns, :weights, :query_options, :zero_terms_all

      def initialize(fields, options, unsupported)
        boosts = Array(fields).to_h do |field|
          name, boost = field.to_s.split("^", 2)
          [name, boost && Float(boost)]
        end
        @columns = boosts.keys
        @weights = boosts.transform_values { |boost| boost || 1.0 } if boosts.values.any?
        @query_options = {operator: :or}
        @zero_terms_all = false
        options.each { |key, value| apply(key.to_sym, value, unsupported) }
      end

      # Narrows the fields (and their boosts) to the given columns.
      def restrict(columns)
        @columns = columns
        @weights = @weights&.slice(*columns)
        self
      end

      private

      def apply(key, value, unsupported)
        case key
        when :operator
          operator = value.to_s.downcase.to_sym
          raise Noiseless::SearchError, "operator must be and or or, got #{value.inspect}" unless %i[and or].include?(operator)
          @query_options[:operator] = operator
        when :minimum_should_match then @query_options[:minimum_should_match] = value
        when :zero_terms_query then @zero_terms_all = value.to_s == "all"
        when :type
          if TYPES.key?(value.to_s)
            @query_options.merge!(TYPES[value.to_s])
          else
            unsupported.decorative("multi_match type #{value.inspect}")
          end
        when *IGNORED then nil
        else unsupported.decorative("text option #{key}")
        end
      end
    end
  end
end
