# frozen_string_literal: true

module SqliteSearch
  module Vec
    class Backend
      def initialize(definition)
        @definition = definition
      end

      def embed_and_store(record)
        id = record.public_send(record.class.primary_key)
        unless id.is_a?(Integer)
          raise SqliteSearch::Error,
            "vec indexing requires an integer primary key (used as the vec rowid), " \
            "but #{record.class.name}##{record.class.primary_key} is #{id.class}."
        end

        model = @definition.neighbor_model
        text = SqliteSearch::Vec.text_for(record, @definition.columns)
        if text.empty?
          model.where(id: id).delete_all
          return
        end

        vector = @definition.embed(text, record_model: record.class) # compute first; if this raises, old row is untouched
        model.transaction do
          model.where(id: id).delete_all
          model.create!(id: id, embedding: vector)
        end
      end

      def remove(record)
        id = record.public_send(record.class.primary_key)
        @definition.neighbor_model.where(id: id).delete_all
      end

      def reembed(model)
        @definition.neighbor_model.delete_all
        model.find_each { |record| embed_and_store(record) }
      end
    end
  end
end
