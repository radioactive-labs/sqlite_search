# sqlite_search — noiseless Adapter Design

- **Date:** 2026-10-17
- **Status:** Approved for planning
- **Builds on:** FTS5 core, vec, and hybrid (v0.1). Adds an opt-in adapter for [noiseless](https://github.com/seuros/noiseless) plus the small core additions it needs.

## Motivation

noiseless is a backend-agnostic search DSL for Rails (OpenSearch, Elasticsearch, Typesense, PostgreSQL). Apps written against it should be able to run on SQLite — for development, tests, or small deployments — by setting `adapter: sqlite` in `config/noiseless.yml`. The audience is **noiseless users moving to SQLite**, so breadth of AST coverage matters: a query that works on Elasticsearch should either work here with documented differences, or fail loudly.

## Decisions log (settled in brainstorming)

| Decision | Choice |
|---|---|
| Audience | noiseless users on SQLite; breadth of AST coverage over minimal mapping |
| Packaging | **Opt-in file inside sqlite_search** (`require "sqlite_search/noiseless"`); noiseless is not a gemspec dependency |
| Text query, no covering `fts5_scope` | **Fall back to `LIKE`** on real text columns (score 1.0), like the PG adapter's ILIKE fallback |
| Vector query, no matching `vec_scope` | Always raise (no meaningful fallback) |
| Hybrid weights | **Weighted RRF**: per-arm weights in `Hybrid.rrf`, also exposed on `hybrid_scope` |
| Unsupported nodes | **Raise by default** (`unsupported: :strict`); `unsupported: :lax` splits: narrowing nodes return zero hits, decorative nodes are skipped with a warning |
| Text semantics | Match ES where FTS5 can: default operator OR, `operator: "and"`, phrase types, field boosts, `zero_terms_query`, `minimum_should_match` (expanded, capped); `fuzziness` unsupported |

## Constraints

- noiseless requires **Ruby >= 4.0 and Rails >= 8.1**; sqlite_search supports Rails 8.0+. The adapter is never loaded unless required, and runs in its own CI job.
- `Noiseless::Adapters.lookup(name)` resolves `const_get(name.to_s.classify)` inside `Noiseless::Adapters`, so `adapter: sqlite` resolves `Noiseless::Adapters::Sqlite`. Defining that constant from our gem works once our file is required (noiseless's Zeitwerk loader only autoloads its own directory).
- noiseless adapters return Elasticsearch-shaped hashes; `Noiseless::ResponseFactory` builds results from them. The PostgreSQL adapter (no HTTP, AR scopes, no-op writes, `Async(finished: false)`) is the template.

## Part A — Core additions (public sqlite_search API)

Each is useful on its own and is a prerequisite for the adapter.

### A1. `vec_scope` accepts a precomputed vector

```ruby
Post.semantic_search(vector: [0.1, ...], k: 20, threshold: 0.3)
```

- New `vector:` keyword. Exactly one of the positional query or `vector:`; both raises `SqliteSearch::Error`. A blank query with no `vector:` still returns `.none`.
- `vector.size != definition.dimensions` raises `SqliteSearch::Error` (before sqlite-vec sees it). The embedder is not called.
- Everything downstream of the embed step is unchanged: KNN, pre-filter via chaining, `threshold:`, `<name>_distance` / `<name>_similarity` columns.

### A2. Weighted RRF

- `SqliteSearch::Hybrid.rrf(ids_a, ids_b, k: 60, weights: [1.0, 1.0])` scores each id as `w_a/(k + rank_a) + w_b/(k + rank_b)` (ranks 1-based; a missing arm contributes 0).
- Implemented directly instead of via `Neighbor::Reranking.rrf` (which has no weights). With default weights the scores are identical to today's. Ties break by first appearance (list a, then list b), which makes the order deterministic.
- Exactly 2 weights, each finite and `>= 0`; otherwise `SqliteSearch::Error`. Both zero raises too (every score would be 0).
- A weight of 0 turns that arm off: its ids contribute nothing and are not added to the fused list.
- `hybrid_scope` calls gain `fts5_weight:` and `vec_weight:` (default `1.0`), passed through to `rrf`. A zero-weight arm is not run at all (a zero `vec_weight:` makes no embedder call).

### A3. FTS5 query options

`fts5_scope` calls gain options, all defaulting to current behavior:

```ruby
Post.search("coffee", columns: [:title])                  # restrict to these FTS columns
Post.search("hot coffee", operator: :or)                  # OR-join terms (default :and)
Post.search("hot coffee", phrase: true)                   # whole input as one phrase
Post.search("hot coffee tea", minimum_should_match: 2)    # at least 2 terms
Post.search("coffee").order_by_rank(weights: { title: 3.0 })
```

- **`columns:`** wraps the sanitized expression in an FTS5 column filter: `{title body} : (expr)`. Each column must be one of the definition's `against:` columns, else `SqliteSearch::Error`. Column names come from the definition, never from the caller's string.
- **`operator:`** — `:and` (default) or `:or`, applied by `SqliteSearch::Query` when joining terms. Quoted phrases stay phrases.
- **`phrase: true`** — the sanitized terms become a single FTS5 phrase `"a b c"`; combined with `prefix: true` the phrase's last term gets `*` (FTS5 `"a b"*` form).
- **`minimum_should_match: n`** — the n-of-m combinations of terms as OR-ed AND groups: 2 of `a b c` → `(a AND b) OR (a AND c) OR (b AND c)`. Accepts an integer, a negative integer (m - n), or a percentage string (`"75%"`, floor, ES rules). Clamped to `1..m`. **Capped at 6 terms**: above the cap `SqliteSearch::Query` raises `SqliteSearch::Error` (the adapter turns this into strict/lax handling, see B5). `n == m` is plain AND; `n == 1` is plain OR.
- **`order_by_rank(weights:)`** — per-query `bm25()` weights keyed by FTS column; unlisted columns get `0.0` when `weights:` is given. Unknown columns, negative, or non-finite weights raise `SqliteSearch::Error`. Without it, the `against:` weights apply (unchanged).
- **`raw:`** bypasses the sanitizer, so combining it with any of the options above raises `SqliteSearch::Error`.
- `SqliteSearch::Query.build(raw, prefix:, operator:, phrase:, minimum_should_match:)` carries the new options; all output stays sanitized.

### A4. Definition lookup by fields

- `Model.sqlite_search_fts5_for(fields)` → the `Fts5::Definition` whose `against:` columns are a superset of `fields` (as strings). Several match → fewest columns wins; tie → declaration order. None → `nil`.
- `Model.sqlite_search_vec_for(field)` → the `Vec::Definition` named `field`, or `nil`. (noiseless's `vector(field, embedding)` passes the vec scope name as `field`.)

## Part B — The adapter

### B1. Files

- `lib/sqlite_search/noiseless.rb` — entry point. Requires `noiseless`, `sqlite_search`, and the files below.
- `lib/sqlite_search/noiseless_adapter/sqlite.rb` — `Noiseless::Adapters::Sqlite < Noiseless::Adapter`.
- `lib/sqlite_search/noiseless_adapter/unsupported.rb` — per-query strict/lax policy (B5).
- `lib/sqlite_search/noiseless_adapter/text_options.rb` — ES `multi_match`/`combined_fields` options → A3 options.
- `lib/sqlite_search/noiseless_adapter/translator.rb` — AST → relation + scorer.
- `lib/sqlite_search/noiseless_adapter/response.rb` — records + scorer → ES-shaped hash.

The support module is `SqliteSearch::NoiselessAdapter`, not `SqliteSearch::Noiseless`: a constant named `Noiseless` inside our namespace would shadow the top-level `::Noiseless` for every reference written inside `module SqliteSearch`.

None is loaded by `require "sqlite_search"` or the Railtie.

### B2. Configuration

```yaml
development:
  connections:
    sqlite:
      adapter: sqlite
      unsupported: strict   # default; or lax
```

Any other `unsupported` value raises `ArgumentError` when the adapter is built. `hosts` is ignored.

### B3. Search flow

`search(ast, model_class:, response_type:)` runs inside `Async(finished: false)`, instrumented as `:search` like other adapters, and passes the result through `ResponseFactory.create`. All SQL goes through `model.with_connection` (fiber-safe, multi-db).

**Model resolution** (as PG): `model_class` if it is an `ActiveRecord::Base` subclass → a model given to `register_model(model, index_name:)` → `index_name.classify.safe_constantize` if it is an AR model. Otherwise `Noiseless::SearchError`.

**Translation order:**

1. **Filters** (`bool.filter`), applied first so they pre-filter every arm:
   - scalar → `where(field => value)`; array → `where(field => values)`; range hash (`gte/lte/gt/lt`) → comparison clauses; a nil bound is open-ended, as in Elasticsearch.
   - geo filter or a field that is not a column → unsupported, narrowing (B5).
2. **Must clauses** (`bool.must`), AND-ed:
   - `Match`, `MultiMatch`, `CombinedFields`: options mapped by B4. Fields that are neither table columns nor FTS columns of a model `fts5_scope` are dropped before the covering-index lookup, each reported as unsupported, decorative; none left → unsupported, narrowing. If `sqlite_search_fts5_for(fields)` finds a definition for the remaining fields, chain `public_send(definition.name, query, columns: fields, **mapped)`. Otherwise **LIKE fallback**: `col LIKE ? ESCAPE '\'` with `%term%`, OR-ed across the fields that are text columns (no text column left → unsupported, narrowing). Under the fallback the input is split into sanitized terms, each matched as a substring: `operator: :or` → any term, `:and` → every term, `phrase: true` → the whole input (double quotes removed) as one substring, `minimum_should_match` → any term when it requires one, every term when it requires all, otherwise every term (a subset of the correct results; unsupported, decorative). Boosts and `prefix` have no effect.
   - `Wildcard` → `LIKE` (`*`→`%`, `?`→`_`, existing `%`/`_`/`\` escaped). `Prefix` → `LIKE 'value%'` escaped. `Range` → comparison clauses. Non-column field → unsupported, narrowing.
   - Any other node → unsupported, narrowing.
3. **Vector** (`ast.vector`): `sqlite_search_vec_for(node.field)` or raise. `node.distance_metric` must match the definition (`:cosine`↔cosine; `:l2`/`:euclidean`↔euclidean); a mismatch or `:inner_product` raises. Then `public_send(definition.name, vector: node.embedding, k: node.k)` on the filtered relation, so filters and musts pre-filter the KNN.
4. **Hybrid** (`ast.hybrid`): requires `sqlite_search_fts5_for(hybrid.fields)` (empty `fields` → the model's only `fts5_scope`; zero or several → raise) and the vec definition for `hybrid.vector.field`; either missing raises (no LIKE fallback — it has no ranking to fuse). Non-column `fields` are dropped as for a text match. The distance-mismatch rule of step 3 does not apply: RRF fuses ranks, so the metric is not checked (noiseless always builds the hybrid vector node as cosine). Each arm fetches `hybrid.vector.k` candidates from the filtered relation: FTS via `order_by_rank`, vec via `vector:`; an arm with weight 0 is not run. Fused with `Hybrid.rrf(weights: [text_weight, vector_weight])`; the result relation is in fused order with a fused score. No reranker.
5. **Sort**: explicit sort nodes `reorder` the relation (column fields only; non-column → unsupported, decorative), with the primary key appended as tiebreaker. `_id` sorts by the primary key. A direction other than `asc`/`desc` raises `Noiseless::SearchError`. `_score` with `desc` as the **first** sort keeps relevance order (rank, nearness, fused) and the remaining sorts are appended with `order` as tiebreakers, then the primary key; without relevance it is a no-op. `_score` ascending, or `_score` after another sort → unsupported, decorative (noiseless's `sort` defaults to ascending, so callers pass `:desc`). No usable sort → relevance order when there is one (primary key breaks ties), else primary key.
6. **Pagination**: `total` = count of the relation before `limit/offset`; capped at `k` for vector and hybrid. Offset pagination from `ast.paginate` (default page 1, 20 per page).
7. **Remaining root options**: `search_after`, non-empty `bool.should`, image search, an inner join → unsupported, narrowing. Aggregations, collapse, search pipeline, conversational (RAG), other joins, `remove_duplicates`, `facet_sample_slope`, `pinned_hits` → unsupported, decorative.

**Zero hits short-circuit.** Any path that can match nothing (a narrowing node under `:lax`, a text clause whose input sanitizes to nothing without `zero_terms_query: "all"`, an empty fused list) aborts translation and returns an empty response. It never continues with a `.none` relation, because the vec scope rebuilds its pre-filter from `all.only(:where, :joins)`, which drops `none` and would widen the search.

**Scores (`_score`):**

| Query | Score |
|---|---|
| exactly one FTS must clause, no vector/hybrid | `<name>_rank` (bm25, higher is better; boosts applied) |
| vector, cosine | `<name>_similarity` |
| vector, euclidean | `1 / (1 + distance)` |
| hybrid | fused RRF score |
| otherwise (LIKE, several FTS musts, filters only) | `1.0` |

### B4. ES text options → FTS5

| ES option (`multi_match` / `combined_fields`) | Translation |
|---|---|
| none (default) | `operator: :or` — ES's default |
| `operator: "and"` / `"or"` | `operator:` |
| `type: "best_fields"` / `"most_fields"` / `"cross_fields"` | bm25 across the listed columns (match set identical; scores differ) |
| `type: "phrase"` | `phrase: true` |
| `type: "phrase_prefix"` | `phrase: true, prefix: true` |
| `type: "bool_prefix"` | `prefix: true` (operator as given) |
| fields with `"title^3"` | strip `^n`; `order_by_rank(weights:)` with each listed field's boost (default 1.0) when any field is boosted |
| `minimum_should_match` | `minimum_should_match:` (above 6 terms → unsupported, narrowing; `:lax` falls back to AND, a subset of the correct results) |
| `zero_terms_query: "all"` | if the query sanitizes to nothing, the clause is skipped instead of matching none |
| `boost`, `tie_breaker`, `analyzer`, `auto_generate_synonyms_phrase_query`, `lenient` | ignored silently (score-only or not applicable) |
| `fuzziness`, `prefix_length`, `max_expansions`, `fuzzy_transpositions` | unsupported; `:strict` raises, `:lax` ignores (can only drop matches, never add wrong ones) |
| any other key | unsupported, decorative |

`Match` (no options in noiseless) → default row: OR of terms on one column.

### B5. Unsupported handling

| Kind | `:strict` (default) | `:lax` |
|---|---|---|
| Narrowing (geo, `search_after`, `should`, image search, inner join, non-column filter/must field, unknown must node or filter value, over-cap `minimum_should_match`) | raise `Noiseless::SearchError` | zero hits (`minimum_should_match` over cap: AND instead) |
| Decorative (aggregations, collapse, pipeline, conversational, non-inner joins, `remove_duplicates`, `facet_sample_slope`, `pinned_hits`, non-column sort, `_score` ascending or after other sorts, non-column text field (when others remain), in-between `minimum_should_match` on the LIKE fallback, unknown text option, `fuzziness`) | raise `Noiseless::SearchError` | skip, one `ActiveRecord::Base.logger&.warn { ... }` per query listing what was skipped |

The error message names the node or option and suggests `unsupported: lax`.

### B6. Response

```ruby
{
  "took" => elapsed_ms, "timed_out" => false,
  "_shards" => { "total" => 1, "successful" => 1, "skipped" => 0, "failed" => 0 },
  "hits" => {
    "total" => { "value" => total, "relation" => "eq" },
    "max_score" => first_score_or_nil,
    "hits" => [{ "_index" => table_name, "_id" => id.to_s, "_score" => score,
                 "_source" => record.as_json(root: false, except: score_columns) }]
  }
}
```

Score columns (`*_rank`, `*_distance`, `*_similarity`, `*_score` added by our scopes) are excluded from `_source`. `as_json` gives JSON-typed values (as the other noiseless adapters do), and `root: false` keeps `include_root_in_json` from wrapping them.

### B7. Writes and index operations

The table is the index; `fts5_scope` / `vec_scope` callbacks keep it current. As in the PG adapter:

- `index_document`, `update_document`, `delete_document`, `bulk` → no-op, `"result" => "noop"` per item.
- `create_index`, `delete_index`, `refresh_index` → acknowledged no-ops (indexes come from migrations).
- `index_exists?` → `model.table_exists?`; `document_exists?` → `model.exists?(id)`.
- `cluster.health` → `SELECT 1` via `with_connection`; green on success, red with the message on failure.
- `search_raw` (a raw Elasticsearch body) has no SQLite translation → raises `Noiseless::SearchError` instead of the base adapter's empty stub.

## Error handling

- Unsupported under `:strict` → `Noiseless::SearchError` (B5).
- Configuration errors, regardless of mode → `Noiseless::SearchError`: missing vec scope, distance mismatch or `inner_product` (`vector` queries only; hybrid fuses ranks, so the metric is not checked), wrong vector dimensions, hybrid without a covering or unambiguous fts5 scope, unresolvable model.
- `SqliteSearch::Error` and other `StandardError` during search → wrapped in `Noiseless::SearchError` with the original message. `ActiveRecord::ConnectionNotEstablished` → `Noiseless::ConnectionError`. Existing `Noiseless::Error`s pass through.
- Core (Part A) errors are `SqliteSearch::Error`, as today.

## Testing strategy

- **Part A** — in the existing suites and CI matrix: `vec_query_test` (`vector:` happy path, both-args error, dimension error, embedder not called), `hybrid_test` (weighted scores, default-weight parity with today's fused scores, tie order, invalid weights, `fts5_weight:`/`vec_weight:` on the scope), `query_test` (`operator:`, `phrase:`, `minimum_should_match:` expansion incl. percentages/negatives/cap, still injection-safe), `rank_test` (`columns:`, `order_by_rank(weights:)`), `definition_lookup_test` (`sqlite_search_fts5_for` / `_vec_for` selection rules).
- **Part B** — `test/noiseless_adapter/*_test.rb`, skipped when `noiseless` cannot be loaded. Queries are built with noiseless's own `QueryBuilder` over a real `Noiseless::Model` subclass and run through `adapter.search(...).wait` (plus one `execute_sync` through a named connection); assertions on records, `_score`, totals. Coverage: filters (scalar/array/range), LIKE fallback and escaping, FTS mapping (default OR, `operator`, each `type`, boosts, `minimum_should_match`, `zero_terms_query`), vector (cosine/euclidean, pre-filter, distance mismatch), hybrid (weights, missing arms), sort/pagination/totals, `:strict` vs `:lax` for each unsupported kind, response shape, no-op writes, model resolution, error wrapping.
- **CI** — new job on Ruby 4.0 + Rails 8.1 with `gemfiles/noiseless.gemfile` (adds `noiseless`, `neighbor`, `sqlite-vec`) running the full suite.

## Documentation

README gains a **Using with noiseless** section: `require "sqlite_search/noiseless"`, `noiseless.yml` config, which scopes back which queries, `strict`/`lax`, a support matrix, and known differences: analyzer/stemming come from the FTS5 tokenizer, LIKE fallback is substring-only, scores are not comparable to ES, `fuzziness` is unsupported, writes are no-ops. Part A options documented in their existing sections.

## Out of scope

- Reranking for noiseless hybrid queries.
- `search_after` keyset pagination.
- Aggregations via `GROUP BY`.
- `adapter: sqlite3` alias.
- `minimum_should_match` beyond 6 terms.
