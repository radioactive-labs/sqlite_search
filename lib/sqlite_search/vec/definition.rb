# frozen_string_literal: true

require "sqlite_search/vec"

module SqliteSearch
  module Vec
    class Definition
      attr_reader :model, :name, :columns, :dimensions, :distance, :table_name

      def initialize(model:, name:, against:, dimensions:, distance: :cosine, embedder: nil)
        @model = model
        @name = name.to_sym
        @columns = SqliteSearch::Vec.columns_for(against)
        @dimensions = dimensions
        @distance = distance
        @embedder = embedder
        @table_name = "#{model.table_name}_#{@name}_vec"
      end

      def column_names = columns.map(&:to_s)
      def similarity_method = "#{name}_similarity"

      def embed(text, record_model: model)
        callable = @embedder || SqliteSearch.config.embedder
        raise SqliteSearch::Error, "No embedder registered. Call SqliteSearch.embedder { |text, model:, scope:| ... }." unless callable
        vector = callable.call(text, model: record_model, scope: name)
        if vector.nil? || vector.length != dimensions
          raise SqliteSearch::Error, "Embedder returned #{vector&.length.inspect}-dim vector for #{model.name}##{name}, expected #{dimensions}."
        end
        vector
      end

      def neighbor_model
        @neighbor_model ||= begin
          tbl = table_name
          dims = dimensions
          Class.new(ActiveRecord::Base) do
            self.table_name = tbl
            self.primary_key = "id"
            has_neighbors :embedding, dimensions: dims
          end
        end
      end
    end
  end
end
