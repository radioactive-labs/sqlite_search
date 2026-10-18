# frozen_string_literal: true

module Noiseless
  module Adapters
    # noiseless adapter backed by sqlite_search. The table is the index:
    # searches translate the AST into sqlite_search scopes on the model, and
    # document writes are no-ops because fts5_scope/vec_scope callbacks keep
    # the indexes current.
    class Sqlite < Noiseless::Adapter
      DEFAULT_PER_PAGE = 20

      def initialize(hosts: [], unsupported: :strict, **connection_params)
        @unsupported = SqliteSearch::NoiselessAdapter::Unsupported.mode(unsupported)
        @models = {}
        super(hosts: [], **connection_params)
      end

      def async_context? = false

      def register_model(model_class, index_name:)
        @models[index_name.to_s] = model_class
      end

      def search(ast_node, model_class: nil, response_type: nil, **)
        Async(finished: false) do
          raw_response = instrument(:search, indexes: ast_node.indexes, query: {}) do
            execute_ast(ast_node, model_class)
          end
          ResponseFactory.create(raw_response, model_class: model_class, response_type: response_type,
            query_hash: page_window(ast_node.paginate))
        end
      end

      # Raw Elasticsearch bodies have no SQLite translation; refuse up front
      # rather than answering with the base adapter's empty stub.
      def search_raw(*, **)
        raise Noiseless::SearchError, "raw queries are not supported by the sqlite adapter"
      end

      def cluster = ClusterAPI.new

      class ClusterAPI
        def health(**)
          ActiveRecord::Base.with_connection { |conn| conn.select_value("SELECT 1") }
          {"cluster_name" => "sqlite", "status" => "green", "number_of_nodes" => 1}
        rescue => e
          {"cluster_name" => "sqlite", "status" => "red", "error" => e.message}
        end
      end

      private

      def execute_ast(ast, model_class)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        model = resolve_model(ast.indexes, model_class)
        unsupported = SqliteSearch::NoiselessAdapter::Unsupported.new(@unsupported)
        window = page_window(ast.paginate)
        model.with_connection do
          result = SqliteSearch::NoiselessAdapter::Translator.new(model, unsupported).call(ast)
          log_skipped(unsupported.skipped)
          total = result.relation.count
          total = [total, result.cap].min if result.cap
          records = result.relation.offset(window[:from]).limit(window[:size]).to_a
          SqliteSearch::NoiselessAdapter::Response.build(records, model: model, total: total, scorer: result.scorer,
            score_columns: result.score_columns, started: started)
        end
      rescue SqliteSearch::NoiselessAdapter::NoHits
        log_skipped(unsupported.skipped)
        SqliteSearch::NoiselessAdapter::Response.empty(started: started)
      rescue ActiveRecord::ConnectionNotEstablished => e
        raise Noiseless::ConnectionError, "sqlite unreachable: #{e.message}"
      rescue Noiseless::Error
        raise
      rescue => e
        raise Noiseless::SearchError, "sqlite search failed: #{e.message}"
      end

      def page_window(paginate)
        page = paginate&.page || 1
        size = paginate&.per_page || DEFAULT_PER_PAGE
        {from: (page - 1) * size, size: size}
      end

      def log_skipped(skipped)
        return if skipped.empty?
        ActiveRecord::Base.logger&.warn { "sqlite_search noiseless adapter skipped unsupported #{skipped.join(", ")}" }
      end

      def resolve_model(indexes, model_class)
        find_model(indexes, model_class) or
          raise Noiseless::SearchError, "no ActiveRecord model for index #{indexes&.first.inspect}"
      end

      # A Noiseless::Model search class arrives as model_class on the standard
      # execute path; only an ActiveRecord model can back a SQLite search, so
      # fall through to the index name for anything else.
      def find_model(indexes, model_class = nil)
        return model_class if active_record?(model_class)
        name = indexes&.first&.to_s
        return unless name
        @models.fetch(name) do
          candidate = name.classify.safe_constantize
          candidate if active_record?(candidate)
        end
      end

      def active_record?(klass) = klass.is_a?(Class) && klass < ActiveRecord::Base

      def execute_bulk(actions, **)
        items = actions.map { |action| action.to_h { |op, meta| [op.to_s, noop(meta[:_index], meta[:_id])] } }
        {"items" => items, "errors" => false}
      end

      def execute_index_document(index, id, _document, **) = noop(index, id)

      def execute_update_document(index, id, _changes, **) = noop(index, id)

      def execute_delete_document(index, id, **) = noop(index, id)

      def execute_index_exists?(index_name) = find_model([index_name])&.table_exists? || false

      def execute_document_exists?(index, id) = find_model([index])&.exists?(id) || false

      def noop(index, id) = {"_index" => index, "_id" => id, "result" => "noop"}
    end
  end
end
