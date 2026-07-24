# frozen_string_literal: true

module SqliteSearch
  # Converts free user text into a safe FTS5 MATCH string.
  # Only quoted phrases and term characters (Unicode alphanumerics and
  # underscore; this does NOT strip to ASCII, so accented/non-Latin words
  # like "café" or "日本語" survive) make it through; everything else (FTS5
  # operators, punctuation) is dropped, so untrusted input cannot inject
  # MATCH syntax. Terms are AND-joined. Returns nil when nothing usable.
  class Query
    PHRASE = /"([^"]+)"/
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
      tokens = phrases + words
      return nil if tokens.empty?

      tokens[-1] = "#{tokens[-1]}*" if @prefix && !quoted?(tokens[-1])
      tokens.join(" AND ")
    end

    private

    def phrases
      @raw.scan(PHRASE).map { |(inner)| %("#{inner.strip}") }.reject { |p| p == '""' }
    end

    def words
      @raw.gsub(PHRASE, " ").split(TERM_CHARS).reject { |w| w.empty? || w.match?(RESERVED) }
    end

    def quoted?(token)
      token.start_with?('"')
    end
  end
end
