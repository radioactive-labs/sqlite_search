# frozen_string_literal: true

module SqliteSearch
  # Converts free user text into a safe FTS5 MATCH string.
  # Only quoted phrases and term characters (Unicode alphanumerics and
  # underscore; this does NOT strip to ASCII, so accented/non-Latin words
  # like "café" or "日本語" survive) make it through; everything else (FTS5
  # operators, punctuation) is dropped, so untrusted input cannot inject
  # MATCH syntax. Terms are AND-joined. Returns nil when nothing usable.
  class Query
    # A quoted phrase, or a run of text between quotes. A quote with no partner
    # matches neither and is skipped.
    SEGMENT = /"([^"]*)"|([^"]+)/
    TERM_CHARS = /[^[:alnum:]_]+/
    RESERVED = /\A(?:AND|OR|NOT|NEAR)\z/

    def self.build(raw, prefix: false)
      new(raw, prefix: prefix).to_match
    end

    def initialize(raw, prefix: false)
      @raw = raw.to_s.scrub
      @prefix = prefix
    end

    def to_match
      tokens = tokenize
      return nil if tokens.empty?

      tokens[-1] = "#{tokens[-1]}*" if @prefix && !quoted?(tokens[-1])
      tokens.join(" AND ")
    end

    private

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
