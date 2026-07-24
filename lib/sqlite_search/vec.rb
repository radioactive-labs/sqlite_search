# frozen_string_literal: true

module SqliteSearch
  module Vec
    @loaded = false

    module_function

    # Lazily load the optional vector dependencies. Raises a clear error when
    # they are missing so a declared vec_scope fails at boot, not mid-query.
    def load!
      return if @loaded
      begin
        require "neighbor"
        require "sqlite_vec"
      rescue LoadError => e
        raise SqliteSearch::Error,
          "Vector search needs the `neighbor` and `sqlite-vec` gems. " \
          "Add them to your Gemfile. (#{e.message})"
      end
      Neighbor::SQLite.initialize!
      @loaded = true
    end

    def columns_for(against)
      case against
      when Array then against.map(&:to_sym)
      else [against.to_sym]
      end
    end

    # Text handed to the embedder: the against columns joined, blanks dropped.
    def text_for(record, columns)
      columns.map { |c| record.public_send(c) }.reject { |v| v.nil? || v.to_s.strip.empty? }.join("\n")
    end
  end
end
