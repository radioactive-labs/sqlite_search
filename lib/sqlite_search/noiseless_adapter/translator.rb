# frozen_string_literal: true

module SqliteSearch
  module NoiselessAdapter
    # Turns a noiseless AST into an ActiveRecord relation over one model, plus
    # how to score each returned record. Filters run first so they pre-filter
    # every arm (text, KNN, hybrid).
    class Translator
      Result = Struct.new(:relation, :scorer, :score_columns, :cap, :relevance)
      CONSTANT_SCORE = ->(_record) { 1.0 }
      RANGE_OPERATORS = {gte: :gteq, lte: :lteq, gt: :gt, lt: :lt}.freeze
      SORT_DIRECTIONS = {"asc" => :asc, "desc" => :desc}.freeze
      VECTOR_DISTANCES = {cosine: :cosine, l2: :euclidean, euclidean: :euclidean}.freeze
      HYBRID_SCORE = "noiseless_hybrid_score"

      def initialize(model, unsupported)
        @model = model
        @unsupported = unsupported
      end

      def call(ast)
        check_root_options(ast)
        relation = apply_filters(@model.all, ast.bool.filter)
        relation, text_clauses = apply_musts(relation, ast.bool.must)
        result = if ast.hybrid_search?
          hybrid(relation, ast.hybrid)
        elsif ast.vector_search?
          vector(relation, ast.vector)
        elsif text_clauses.one?
          ranked(relation, *text_clauses.first)
        else
          Result.new(relation: relation, scorer: CONSTANT_SCORE, score_columns: [], relevance: false)
        end
        result.relation = apply_sort(result.relation, ast.sort, relevance: result.relevance)
        result
      end

      private

      def check_root_options(ast)
        @unsupported.narrowing!("search_after") if ast.cursor_pagination?
        @unsupported.narrowing!("bool should clauses") if ast.bool.should.any?
        @unsupported.narrowing!("image search") if ast.image_search?
        @unsupported.decorative("aggregations") if ast.aggregated?
        @unsupported.decorative("collapse") if ast.collapsed?
        @unsupported.decorative("search pipeline") if ast.has_pipeline?
        @unsupported.decorative("conversational search") if ast.conversational?
        @unsupported.narrowing!("inner join") if ast.joins.any?(&:inner_join?)
        @unsupported.decorative("joins") if ast.has_joins?
        @unsupported.decorative("remove_duplicates") unless ast.remove_duplicates.nil?
        @unsupported.decorative("facet_sample_slope") unless ast.facet_sample_slope.nil?
        @unsupported.decorative("pinned_hits") unless ast.pinned_hits.nil?
      end

      def apply_filters(relation, nodes)
        nodes.reduce(relation) do |rel, node|
          field = node.field.to_s
          value = node.value
          if value.is_a?(Hash)
            keys = value.keys.map(&:to_sym)
            @unsupported.narrowing!("geo filter on #{field}") if keys.intersect?(Noiseless::Adapter::GEO_FILTER_KEYS)
            @unsupported.narrowing!("filter value #{value.inspect} on #{field}") unless keys.any? && (keys - RANGE_OPERATORS.keys).empty?
            where_range(rel, column!(field, "filter"), value.transform_keys(&:to_sym))
          else
            rel.where(column!(field, "filter") => value)
          end
        end
      end

      def apply_musts(relation, nodes)
        text_clauses = []
        nodes.each do |node|
          relation, clause = case node
          when Noiseless::AST::Match
            text_clause(relation, node.value, [node.field], {})
          when Noiseless::AST::MultiMatch, Noiseless::AST::CombinedFields
            text_clause(relation, node.query, node.fields, node.options)
          when Noiseless::AST::Wildcard
            pattern = @model.sanitize_sql_like(node.value.to_s).tr("*", "%").tr("?", "_")
            [where_like(relation, column!(node.field, "wildcard"), pattern), nil]
          when Noiseless::AST::Prefix
            [where_like(relation, column!(node.field, "prefix"), "#{@model.sanitize_sql_like(node.value.to_s)}%"), nil]
          when Noiseless::AST::Range
            [where_range(relation, column!(node.field, "range"), {gte: node.gte, lte: node.lte, gt: node.gt, lt: node.lt}.compact), nil]
          else
            @unsupported.narrowing!("#{node.class.name.demodulize} query")
          end
          text_clauses << clause if clause
        end
        [relation, text_clauses]
      end

      def ranked(relation, definition, text)
        Result.new(
          relation: relation.order_by_rank(weights: text.weights),
          scorer: ->(record) { record.public_send(definition.rank_column).to_f },
          score_columns: [definition.rank_column],
          relevance: true
        )
      end

      # A covering fts5_scope serves the clause (and is returned for ranking);
      # otherwise LIKE on the text columns stands in. Returns
      # [relation, [definition, text] or nil].
      def text_clause(relation, query, fields, options)
        text = text_options(fields, options)
        # FTS tokenization on purpose, for the LIKE path too: reserved words
        # (AND/OR/NOT/NEAR) and punctuation drop, so "!!!" has no terms.
        if SqliteSearch::Query.build(query).nil?
          return [relation, nil] if text.zero_terms_all
          raise NoHits
        end
        definition = @model.sqlite_search_fts5_for(text.columns)
        return [like_text(relation, query, text), nil] unless definition

        [fts(relation, definition, query, text), [definition, text]]
      end

      # Fields that are neither table columns nor FTS columns are dropped, so
      # they cannot defeat the covering lookup; dropping all of them narrows.
      def text_options(fields, options)
        text = TextOptions.new(fields, options, @unsupported)
        kept, dropped = text.columns.partition { |field| searchable_columns.include?(field) }
        @unsupported.narrowing!("text match on non-column fields #{dropped.join(", ")}") if kept.empty?
        dropped.each { |field| @unsupported.decorative("text match on non-column field #{field}") }
        text.restrict(kept)
      end

      # Table columns plus FTS columns (an fts5 source: definition indexes
      # columns the table does not have).
      def searchable_columns
        @searchable_columns ||= @model.column_names | @model.sqlite_search_fts5_definitions.values.flat_map(&:column_names)
      end

      def fts(relation, definition, query, text)
        relation.public_send(definition.name, query, columns: text.columns, **text.query_options)
      rescue SqliteSearch::Query::TooManyTerms => e
        @unsupported.decorative("#{e.message} (fell back to AND)")
        relation.public_send(definition.name, query, columns: text.columns,
          **text.query_options.except(:minimum_should_match).merge(operator: :and))
      end

      # Substring stand-in for FTS: each term must appear in at least one of
      # the text columns; OR-ed or AND-ed per operator, the whole input for a
      # phrase. minimum_should_match is exact when it requires one term or all
      # of them; in between every term is required (a subset of the correct
      # results, never a superset).
      def like_text(relation, query, text)
        columns = text.columns.select { |column| %i[string text].include?(@model.columns_hash[column]&.type) }
        @unsupported.narrowing!("text match on non-text fields #{text.columns.join(", ")}") if columns.empty?
        (text.columns - columns).each { |column| @unsupported.decorative("text match on non-text field #{column}") }
        options = text.query_options
        terms = options[:phrase] ? [query.to_s.delete('"').squish] : query.to_s.scrub.split(/[^[:alnum:]_]+/).reject(&:empty?)
        raise NoHits if terms.empty?

        any_column = "(#{columns.map { |column| "#{qualified(column)} LIKE ? ESCAPE '\\'" }.join(" OR ")})"
        binds = terms.flat_map { |term| ["%#{@model.sanitize_sql_like(term)}%"] * columns.size }
        relation.where(terms.map { any_column }.join(like_joiner(options, terms.size)), *binds)
      end

      def like_joiner(options, count)
        msm = options[:minimum_should_match]
        return (options[:operator] == :or) ? " OR " : " AND " unless msm

        required = SqliteSearch::Query.required_terms(msm, count)
        return " OR " if required == 1
        @unsupported.decorative("minimum_should_match on LIKE fallback (fell back to AND)") if required < count
        " AND "
      end

      def where_like(relation, column, pattern)
        relation.where("#{qualified(column)} LIKE ? ESCAPE '\\'", pattern)
      end

      # Table-qualified: a ranked relation joins the FTS table, which has
      # columns of the same names.
      def qualified(column)
        @model.with_connection { |conn| "#{@model.quoted_table_name}.#{conn.quote_column_name(column)}" }
      end

      def vector(relation, node)
        definition = vec_definition(node.field)
        check_distance!(node, definition)
        Result.new(
          relation: relation.public_send(definition.name, vector: node.embedding, k: node.k),
          scorer: vector_scorer(definition),
          score_columns: [definition.distance_method, definition.similarity_method],
          cap: node.k,
          relevance: true
        )
      end

      # Both arms run over the filtered relation and fetch k candidates each;
      # the fused list is cut to k. A zero-weight arm is not run. Fields are
      # handled as for a text match; without fields the model's only
      # fts5_scope serves the text arm. RRF fuses ranks only, so the vector
      # distance_metric is not checked (noiseless always sends cosine).
      def hybrid(relation, node)
        text = node.fields.empty? ? TextOptions.new([], {}, @unsupported) : text_options(node.fields, {})
        fts_definition = hybrid_fts_definition(text.columns)
        vec = vec_definition(node.vector.field)
        k = node.vector.k
        primary_key = @model.primary_key
        text_ids = if node.text_weight.zero? || SqliteSearch::Query.build(node.text_query).nil?
          []
        else
          fts(relation, fts_definition, node.text_query, text).order_by_rank(weights: text.weights).limit(k).pluck(primary_key)
        end
        vector_ids = node.vector_weight.zero? ? [] : relation.public_send(vec.name, vector: node.vector.embedding, k: k).pluck(primary_key)
        fused = SqliteSearch::Hybrid.rrf(text_ids, vector_ids, weights: [node.text_weight, node.vector_weight]).first(k)
        raise NoHits if fused.empty?

        Result.new(
          relation: SqliteSearch::Hybrid.relation(relation, fused, HYBRID_SCORE),
          scorer: ->(record) { record.public_send(HYBRID_SCORE).to_f },
          score_columns: [HYBRID_SCORE],
          cap: k,
          relevance: true
        )
      end

      def vec_definition(field)
        @model.sqlite_search_vec_for(field) or
          raise Noiseless::SearchError, "#{@model.name || @model.table_name} has no vec_scope :#{field}"
      end

      def check_distance!(node, definition)
        return if VECTOR_DISTANCES[node.distance_metric] == definition.distance
        raise Noiseless::SearchError, "vector distance_metric #{node.distance_metric} does not match vec_scope :#{definition.name} (#{definition.distance})"
      end

      def vector_scorer(definition)
        if definition.cosine?
          ->(record) { record.public_send(definition.similarity_method).to_f }
        else
          ->(record) { 1.0 / (1.0 + record.public_send(definition.distance_method).to_f) }
        end
      end

      def hybrid_fts_definition(columns)
        if columns.empty?
          definitions = @model.sqlite_search_fts5_definitions.values
          return definitions.first if definitions.one?
          raise Noiseless::SearchError, "hybrid search without fields needs exactly one fts5_scope, found #{definitions.size}"
        end
        @model.sqlite_search_fts5_for(columns) or
          raise Noiseless::SearchError, "no fts5_scope covers #{columns.join(", ")} for hybrid search"
      end

      # An explicit sort replaces relevance order, unless it starts with
      # _score desc (relevance itself): then relevance order stands and the
      # other sorts break its ties. With no usable sort, relevance order
      # stands. The primary key breaks any remaining ties; _id is the primary
      # key. Without relevance, _score desc is a no-op.
      def apply_sort(relation, nodes, relevance:)
        score_first = false
        orders = []
        nodes.each_with_index do |node, index|
          field = node.field.to_s
          direction = sort_direction(node.direction)
          if field == "_score"
            if index.positive?
              @unsupported.decorative("sort on _score after other fields")
            elsif direction == :asc
              @unsupported.decorative("sort on _score ascending")
            else
              score_first = true
            end
            next
          end
          field = @model.primary_key if field == "_id"
          if @model.columns_hash.key?(field)
            orders << {field => direction}
          else
            @unsupported.decorative("sort on non-column field #{field}")
          end
        end

        keep_relevance = relevance && (score_first || orders.empty?)
        primary_key = @model.primary_key
        orders << {primary_key => :asc} unless orders.any? { |order| order.key?(primary_key) }
        keep_relevance ? relation.order(*orders) : relation.reorder(*orders)
      end

      def sort_direction(direction)
        SORT_DIRECTIONS.fetch(direction.to_s.downcase) do
          raise Noiseless::SearchError, "sort direction must be asc or desc, got #{direction.inspect}"
        end
      end

      # A nil bound is open-ended, as in Elasticsearch.
      def where_range(relation, column, bounds)
        bounds.compact.reduce(relation) do |rel, (operator, value)|
          rel.where(@model.arel_table[column].public_send(RANGE_OPERATORS.fetch(operator), value))
        end
      end

      # The field as a column name, or a narrowing refusal when the table has
      # no such column (a mapping-only field cannot be enforced here).
      def column!(field, what)
        field = field.to_s
        return field if @model.columns_hash.key?(field)
        @unsupported.narrowing!("#{what} on non-column field #{field}")
      end
    end
  end
end
