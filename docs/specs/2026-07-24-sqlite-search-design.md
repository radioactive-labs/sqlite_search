# sqlite_search — Design

- **Date:** 2026-07-24
- **Status:** Approved for planning (FTS5 core first)
- **Scope of this spec:** the full unified vision, with the **FTS5 core (v0.1)** specified in implementation detail and the **vec (v0.2)** and **hybrid (v0.3)** layers specified as design-level fit into the same interface.

## Motivation

`pg_search` gives ActiveRecord apps declarative, composable full-text search — but it is Postgres-only. On SQLite, the options are hand-rolled FTS5 (as in `easy_linkups`) or `litesearch`, which is trigger-based and coupled to the litestack ecosystem. There is no good standalone gem that brings `pg_search`-style ergonomics to SQLite and also covers vector and hybrid search.

`sqlite_search` fills that gap: one gem, declarative named-scope DSL, composable `ActiveRecord::Relation`s, model-owned (callback) index sync that survives `schema.rb` dumps, and pluggable `fts5` / `vec` / `hybrid` backends.

### Prior art we draw from

- **pg_search** — named-scope DSL, multi-column weighting, `.reorder` for rank. We adopt the ergonomics, avoid the implicit-order footgun (see Ranking).
- **litesearch** — SQLite FTS5, but trigger-based and litestack-coupled. We deliberately diverge: callback sync, no litestack.
- **universal_chatbot `Knowledge` engine** — a production RAG stack over SQLite. Direct lessons adopted below (vec0 + `neighbor`, RRF fusion, degradable rerank, schema-dump gotchas).

## Goals / Non-goals

**Goals**
- Declarative, `pg_search`-style search for SQLite, standalone (no litestack).
- FTS5 full-text with BM25, multi-column weights, safe query parsing.
- Composable `ActiveRecord::Relation` output so search intersects arbitrary scopes (e.g. geo/radius).
- Model-owned callback sync; **no triggers** → fully `schema.rb`-compatible.
- Vector search (sqlite-vec via `neighbor`) and hybrid (RRF) fusion behind the same DSL.
- Bring-your-own-model: embedding and reranking are **app-registered callbacks**; the gem bundles no ML.

**Non-goals**
- Generating embeddings or hosting a reranker model (the app supplies these via callbacks).
- Postgres/MySQL support (SQLite only).
- Multi-model global search (`pg_search`'s `multisearch`) in v0.1 — possible later, not now (YAGNI).

## Decisions log (settled)

| Decision | Choice | Rationale |
|---|---|---|
| Scope | Unified gem, `fts5`/`vec`/`hybrid` backends; **FTS5 ships first** | Coherent design now, incremental delivery |
| Coupling | Standalone, no litestack | Portability |
| API | `pg_search`-style named scopes → composable Relation | Familiar, composes with other scopes |
| Sync | Callback-only (model-owned `after_commit`) + `reindex` task | One code path; survives `schema.rb` (triggers don't) |
| Schema | `create_fts5_table` over `create_virtual_table` | Round-trips `schema.rb` (verified) |
| Ordering | No implicit ORDER BY; relevance opt-in via `.order_by_rank` | Avoids the pg_search `.reorder` footgun; composes predictably |
| Query parsing | Safe-by-default sanitizer; `raw:` opt-in | Injection-safe for untrusted end-user input |
| Vec deps | Build on `neighbor` (+ `sqlite-vec`) | Proven in ucb; least code to maintain |
| Embeddings | App-registered `embedder` **block**, signature `\|text, model:, scope:\|`, called at index + query time | Gem owns flow, not the model; symmetric encoder; model/scope let the app route dynamically |
| Reranking | App-registered `reranker` **block**, signature `\|query, documents, model:, scope:\|`; best-effort/degradable | Rerank is the top quality lever but infra-specific; model/scope enable dynamic routing |

## Architecture

A model opts in (auto-included on `ActiveRecord::Base` via a Railtie, or `include SqliteSearch::Model`). Three DSL macros, one per backend:

- `fts5_scope`  → defines a class scope returning an `ActiveRecord::Relation` (pure lexical filter).
- `vec_scope`   → defines a class scope returning a Relation constrained to KNN-matched ids + similarity.
- `hybrid_scope`→ defines a class method returning **fused ranked results** (ids + scores), not a lazy Relation.

Each backend is a swappable object implementing a common interface:

```
Backend#define_index(...)      # migration-helper contribution / table shape
Backend#sync(record)          # write one record into its index (callback path)
Backend#remove(record)        # delete one record from its index
Backend#query(relation, ...)  # produce the search result (Relation or fused list)
```

Composability, stated honestly:
- **FTS5** — a pure chainable `Relation`. Intersects any scope (the geo/radius case).
- **Vec** — a `Relation` on the content model constrained to KNN-matched ids, with similarity exposed. Composes via the id set.
- **Hybrid** — fusion happens in Ruby, so it returns fused/ranked results (ids + scores), optionally re-expressed as a Relation ordered by fused rank. Not lazy. (ucb's `Knowledge::Query` returns hashes for this reason.)

---

## FTS5 core — v0.1 (implementation-detail spec)

### DSL

```ruby
class Post < ApplicationRecord
  fts5_scope :by_body, against: :body
  fts5_scope :full, against: { title: 2.0, body: 1.0 }, tokenizer: "porter unicode61"
end
```

Generates class scopes `.by_body(query, **opts)` and `.full(query, **opts)`, each returning an `ActiveRecord::Relation`.

**Options**
- `against:` — `Symbol` (one column) or `Hash{column => weight}` (multi-column; weights map to `bm25(tbl, w1, w2, …)`).
- `tokenizer:` — default `"porter unicode61"`. Porter stems at the tokenizer level, so no external Snowball step (ucb needed one only because it used the default `unicode61`). Overridable (e.g. `"unicode61"`, `"trigram"`, `"ascii"`).
- `prefix:` — optional FTS5 prefix index config (e.g. `[2, 3]`).
- `table:` — override the derived table name (default `"#{table_name}_#{scope_name}_fts"`).
- `sanitizer:` — override the default query sanitizer.

### Index table topology

One **plain (non-external-content)** FTS5 virtual table per scope. Columns = the `against` columns; `rowid` = model primary key; the table stores its own copy of the text. Matches the `easy_linkups` and ucb pattern. (External-content mode is a possible future option; not v0.1.)

Trade-off noted: two scopes indexing the same columns duplicate storage. Acceptable for v0.1; dedup is a later optimization.

### Migration helper + generator

```ruby
create_fts5_table :posts, :by_body,
  against: :body,
  tokenizer: "porter unicode61",
  backfill: true   # seed from existing rows
```

Wraps `create_virtual_table "<name>", "fts5", ["body", "tokenize = 'porter unicode61'"]` so it round-trips `schema.rb` (verified: `easy_linkups/db/schema.rb` already dumps `create_virtual_table "post_search", "fts5", [...]`). `backfill:` runs the initial `INSERT … SELECT` from the source table.

Generator: `rails g sqlite_search:fts5 Post title body --weights 2,1` scaffolds the migration.

### Sync (callback-only)

On `fts5_scope`, register:
- `after_save_commit` — when any indexed column changed (`saved_change_to_<col>?`): upsert = `DELETE FROM <fts> WHERE rowid = ?` then `INSERT INTO <fts>(rowid, <cols>) VALUES (?, …)` (skip insert when all indexed values are blank).
- `after_destroy_commit` — `DELETE FROM <fts> WHERE rowid = ?`.

All writes via `with_connection` and `sanitize_sql`. Recovery from bulk/raw writes (`insert_all`, `update_all`, imports) that bypass callbacks:
- `Post.reindex(:by_body)` — rebuild one scope's index.
- Rake task `sqlite_search:reindex[Post,by_body]` (and an all-scopes variant).

### Query building

- **Default** `.by_body("coffee shop")` → sanitize → pure filter:
  ```sql
  WHERE posts.id IN (SELECT rowid FROM posts_by_body_fts WHERE posts_by_body_fts MATCH 'coffee AND shop')
  ```
  Composes with any scope (the geo case), no implicit order, no duplicate rows.
- **Relevance opt-in** `.by_body("coffee").order_by_rank` → switch to JOIN form:
  ```sql
  SELECT posts.*, bm25(posts_by_body_fts, <weights>) AS by_body_rank
  FROM posts JOIN posts_by_body_fts ON posts.id = posts_by_body_fts.rowid
  WHERE posts_by_body_fts MATCH ?
  ORDER BY by_body_rank            -- sign-flipped so higher = better; exposed as record.by_body_rank
  ```
- **Escape hatches**: `.by_body(raw: 'a OR b NOT c')` (bypass sanitizer), `.by_body('foo', prefix: true)` (append `*`).

### Query sanitizer (`SqliteSearch::Query`)

Free text → safe MATCH:
1. Extract `"quoted phrases"` verbatim (as FTS5 phrases).
2. Reduce remaining text to allowed-character terms (drop FTS5 operators/special chars).
3. AND the terms/phrases together (configurable to OR).
4. Optional trailing `*` on the last term when `prefix: true`.
5. Blank result → scope returns `.none` (a Relation, so chaining stays safe).

Injection-safe by construction: only allowed characters reach the MATCH string unless `raw:` is used.

Examples:
```
"coffee shop"    => coffee AND shop
'"flat white"'   => "flat white"
"near", prefix   => near*
raw: 'a OR b'    => a OR b            (caller's responsibility)
```

---

## Vec — v0.2 (design-level fit)

```ruby
# Block DSL, not assignment. The callback receives the model class and scope
# name so the app can route dynamically (different embedding model per AR
# model / per named scope).
SqliteSearch.embedder do |text, model:, scope:|
  MyEmbedder.call(text, model:, scope:)   # -> Array<Float>
end

class Post
  vec_scope :semantic, dimensions: 768, distance: :cosine   # optional per-scope embedder: override
end

Post.semantic("coffee near me", k: 20)   # gem embeds the text via the callback -> neighbor KNN -> ids + similarity
```

- **Embedder callback signature:** `|text, model:, scope:|` returning `Array<Float>`. `model` is the ActiveRecord class, `scope` is the named-scope symbol. Same callback is used at index time and query time (symmetric encoder). Registered via the `SqliteSearch.embedder do … end` block; a `vec_scope` may override with `embedder:` (a callable or method symbol). Callbacks that don't need the context can absorb it with `|text, **|`.
- Storage: `create_vec_table :posts, :semantic, dimensions: 768, distance: :cosine` → `create_virtual_table :name, :vec0, ["id integer primary key not null", "embedding float[768] distance_metric=cosine"]` (via `neighbor` + `sqlite-vec`).
- Query: `neighbor`'s `nearest_neighbors(:embedding, query_vec, distance: :cosine)`; similarity = `1 - neighbor_distance`; optional `similarity_threshold`.
- Sync: the gem calls the **app's `embedder`** on the indexed text and stores the returned vector. **Async by default** (embedding is expensive — mirrors ucb's `GenerateChunkEmbeddingJob`); configurable to synchronous.
- Schema: vec0 shadow tables are auto-excluded from the schema dump (the gotcha ucb hit — it excludes them in `application.rb`).

## Hybrid — v0.3 (design-level fit)

```ruby
# Block DSL; same model/scope context as the embedder for dynamic routing.
SqliteSearch.reranker do |query, documents, model:, scope:|
  MyReranker.call(query, documents, model:, scope:)   # -> reordered docs; best-effort
end

class Post
  hybrid_scope :search, fts5: :by_body, vec: :semantic, k: 10, rerank: true   # optional per-scope reranker: override
end

Post.search("coffee near me")   # fused ranked results (ids + scores)
```

**Reranker callback signature:** `|query, documents, model:, scope:|` returning the reordered documents. `model`/`scope` mirror the embedder so a single app can route both by AR model and named scope. Registered via `SqliteSearch.reranker do … end`; a `hybrid_scope` may override with `reranker:`.

Pipeline (adopted from ucb, which found this the highest-quality arrangement):
1. Run both arms independently over an **inflated candidate pool** (`limit * 3`, capped).
2. **Threshold-filter each arm first** (so RRF normalization can't resurrect junk).
3. **RRF fuse**: `score(d) = Σ 1/(k + rank_i(d))`, `k ≈ 10` (via `Neighbor::Reranking.rrf` or a tiny built-in).
4. Optional **rerank** via the app's `reranker` callback — **best-effort**: on failure/outage, log and fall back to pre-rerank order.
5. Truncate to the final `limit`.

Returns fused results (ids + scores), optionally re-expressed as a Relation ordered by fused rank.

## Error handling

- Missing FTS/vec table for a declared scope → actionable error naming the generator/migration to run.
- Blank query → `.none` (keeps the Relation contract).
- Vec dimension mismatch (stored vs. embedder output) → raise.
- `embedder` missing when a `vec_scope` is used → raise with guidance.
- `reranker` failure → degrade to pre-rerank order (never fails the search).

## Testing strategy

Gem ships a dummy ActiveRecord app on SQLite (with `sqlite-vec` loaded for the vec suite):
- FTS5: DSL registration, callback sync (create/update/destroy, changed-column guard), sanitizer (phrases, operators, prefix, blank→none, `raw:`), default filter vs. `.order_by_rank`, multi-column bm25 weights, `create_fts5_table` **schema.rb round-trip**, `reindex` recovery after `insert_all`.
- Vec: stubbed `embedder`; `nearest_neighbors` KNN, similarity/threshold, async sync path, shadow-table schema exclusion.
- Hybrid: threshold-first → RRF ordering; degradable rerank (stubbed `reranker` that raises → pre-rerank order).

## Packaging

- Standalone repo: `radioactive-labs/sqlite_search` (this repo).
- Runtime deps: `activerecord`, `sqlite3`. Vec/hybrid layers add `neighbor` and `sqlite-vec` (required once those backends are used; FTS5 core needs neither).
- Railtie for auto-include + rake tasks + schema-dump configuration.

## Open questions / pre-release checks

- **Name availability:** confirm `sqlite_search` is free on rubygems.org before first release.
- Whether `vec_scope` async sync should ship with a built-in job or require the app to wire one (leaning: gem provides a default job, app can override).
- Whether to offer external-content FTS5 tables as an option (deferred).
- `multisearch`-style cross-model search (deferred).
