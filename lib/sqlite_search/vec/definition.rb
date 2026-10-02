# frozen_string_literal: true

require "sqlite_search/vec"

module SqliteSearch
  module Vec
    class Definition
      attr_reader :model, :name, :columns, :source, :dimensions, :distance, :table_name

      # Text to embed comes from either against: (attributes joined by
      # newlines) or source: (a method returning the text). watch: lists the
      # attributes whose change triggers a re-embed; it defaults to against:.
      def initialize(model:, name:, dimensions:, against: nil, source: nil, watch: nil, distance: :cosine, embedder: nil)
        if against.nil? == source.nil?
          raise SqliteSearch::Error, "vec_scope :#{name} needs exactly one of against: or source:."
        end
        @model = model
        @name = name.to_sym
        @columns = SqliteSearch::Vec.columns_for(against)
        @source = source
        @watch = watch
        @dimensions = dimensions
        @distance = distance.to_sym
        @embedder = embedder
        @table_name = "#{model.table_name}_#{@name}_vec"

        SqliteSearch::Vec.vec0_metric(@distance) # validates the distance is supported
      end

      def column_names = columns.map(&:to_s)
      def watch_names = (@watch || columns).map(&:to_s)

      # Text handed to the embedder: the source text, or the against
      # attributes joined with blanks dropped.
      def text_for(record)
        return record.public_send(source).to_s if source
        columns.map { |c| record.public_send(c) }.reject { |v| v.nil? || v.to_s.strip.empty? }.join("\n")
      end

      def cosine? = distance == :cosine
      def distance_method = "#{name}_distance"
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
          # Subclass the model's abstract parent (ApplicationRecord, or the
          # abstract class of a secondary database) so the vec table is read
          # and written on the model's own database.
          Class.new(model.base_class.superclass) do
            self.table_name = tbl
            self.primary_key = "id"
            has_neighbors :embedding, dimensions: dims
          end
        end
      end
    end
  end
end
