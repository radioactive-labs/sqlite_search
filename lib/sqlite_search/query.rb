# frozen_string_literal: true

module SqliteSearch
  # Converts free user text into a safe FTS5 MATCH string.
  # Only quoted phrases and term characters (Unicode alphanumerics and
  # underscore; this does NOT strip to ASCII, so accented/non-Latin words
  # like "café" or "日本語" survive) make it through; everything else (FTS5
  # operators, punctuation) is dropped, so untrusted input cannot inject
  # MATCH syntax. Terms are AND-joined by default. phrase: true wins over
  # minimum_should_match:, which wins over operator:. Returns nil when nothing
  # usable.
  class Query
    # A quoted phrase, or a run of text between quotes. A quote with no partner
    # matches neither and is skipped.
    SEGMENT = /"([^"]*)"|([^"]+)/
    TERM_CHARS = /[^[:alnum:]_]+/
    RESERVED = /\A(?:AND|OR|NOT|NEAR)\z/
    OPERATORS = {and: " AND ", or: " OR "}.freeze
    # minimum_should_match expands to every n-of-m group of terms, which grows
    # combinatorially, so it stops at this many terms.
    MINIMUM_SHOULD_MATCH_TERM_CAP = 6
    MINIMUM_SHOULD_MATCH = /\A(-?)(\d+)(%?)\z/

    class TooManyTerms < SqliteSearch::Error; end

    def self.build(raw, prefix: false, operator: :and, phrase: false, minimum_should_match: nil, columns: nil)
      new(raw, prefix:, operator:, phrase:, minimum_should_match:, columns:).to_match
    end

    # How many of count terms a minimum_should_match spec requires, by the
    # Elasticsearch rules: an integer, a negative integer (how many terms may
    # be missing), or a percentage of the terms rounded down; clamped to
    # 1..count.
    def self.required_terms(spec, count)
      match = MINIMUM_SHOULD_MATCH.match(spec.to_s.strip)
      unless match
        raise SqliteSearch::Error, "minimum_should_match must be an integer or a percentage, got #{spec.inspect}"
      end
      negative, digits, percent = match.captures
      amount = percent.empty? ? digits.to_i : count * digits.to_i / 100
      (negative.empty? ? amount : count - amount).clamp(1, count)
    end

    def initialize(raw, prefix: false, operator: :and, phrase: false, minimum_should_match: nil, columns: nil)
      @raw = raw.to_s.scrub
      @prefix = prefix
      @joiner = OPERATORS.fetch(operator&.to_sym) do
        raise SqliteSearch::Error, "operator must be :and or :or, got #{operator.inspect}"
      end
      @phrase = phrase
      @minimum_should_match = minimum_should_match
      @columns = Array(columns).map(&:to_s)
    end

    def to_match
      tokens = tokenize
      return nil if tokens.empty?

      expression = @phrase ? phrase(tokens) : terms(tokens)
      @columns.empty? ? expression : "#{column_filter} : (#{expression})"
    end

    private

    def terms(tokens)
      tokens[-1] = "#{tokens[-1]}*" if @prefix && !quoted?(tokens[-1])
      return tokens.join(@joiner) unless @minimum_should_match

      required = required_terms(tokens.size)
      return tokens.join(" AND ") if required == tokens.size
      return tokens.join(" OR ") if required == 1
      if tokens.size > MINIMUM_SHOULD_MATCH_TERM_CAP
        raise TooManyTerms, "minimum_should_match over #{MINIMUM_SHOULD_MATCH_TERM_CAP} terms"
      end
      tokens.combination(required).map { |group| "(#{group.join(" AND ")})" }.join(" OR ")
    end

    # Every word, phrases unwrapped, as one FTS5 phrase. Tokens never contain a
    # double quote inside (tokenize splits on them), so this is one string.
    def phrase(tokens)
      text = %("#{tokens.map { |token| token.delete('"') }.join(" ")}")
      @prefix ? "#{text} *" : text
    end

    def required_terms(count) = self.class.required_terms(@minimum_should_match, count)

    def column_filter
      "{#{@columns.map { |column| %("#{column.gsub('"', '""')}") }.join(" ")}}"
    end

    # Phrases and words in the order they were typed, so prefix: widens the
    # last thing typed: never a finished word that came before a phrase.
    def tokenize
      @raw.scan(SEGMENT).flat_map do |phrase, text|
        if phrase
          phrase.strip.empty? ? [] : [%("#{phrase.strip}")]
        else
          text.split(TERM_CHARS).reject { |w| w.empty? || w.match?(RESERVED) }
        end
      end
    end

    def quoted?(token)
      token.start_with?('"')
    end
  end
end
