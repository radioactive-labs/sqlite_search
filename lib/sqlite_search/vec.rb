# frozen_string_literal: true

module SqliteSearch
  module Vec
    # Supported distance metrics, mapped to the vec0 table's distance_metric name.
    # neighbor computes the distance with the matching vec_distance_* function at
    # query time, so the scope's distance is what ranks results; the table metric
    # is kept in step to keep the schema honest. inner_product is queryable by
    # neighbor but is not a valid vec0 distance_metric, so it is not offered.
    DISTANCE_METRICS = {cosine: "cosine", euclidean: "l2", taxicab: "l1"}.freeze

    @loaded = false

    module_function

    def vec0_metric(distance)
      DISTANCE_METRICS.fetch(distance.to_sym) do
        raise SqliteSearch::Error,
          "Unsupported distance #{distance.inspect}. Use one of: #{DISTANCE_METRICS.keys.join(", ")}."
      end
    end

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
