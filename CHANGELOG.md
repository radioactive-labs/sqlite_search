# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Full-text search over ActiveRecord with SQLite FTS5: the `fts5_scope` DSL, the
  `create_fts5_index` migration helper (round-trips through `schema.rb`), a query
  sanitizer that makes untrusted input safe, BM25 relevance ranking via
  `order_by_rank`, model-owned callback sync, and `Model.reindex` plus a rake task.
- Vector search with [sqlite-vec](https://github.com/asg017/sqlite-vec) through the
  [`neighbor`](https://github.com/ankane/neighbor) gem: the `vec_scope` DSL, the
  `create_vec_index` migration helper, an app-registered `SqliteSearch.embedder`,
  async embedding through `SqliteSearch::EmbedJob` (with a `sync: :inline` option
  and a configurable queue), and `Model.reembed` plus a rake task.
- Hybrid search: `hybrid_scope` fuses an `fts5_scope` and a `vec_scope` with
  Reciprocal Rank Fusion, with an optional, degradable `SqliteSearch.reranker`.
- Exact pre-filtering by chaining: conditions placed before `.search`/`.semantic`
  (for example `Post.where(tenant_id: 5).search("...")`) push into both arms.
- Rails generators for the FTS5 and vec migrations.
- Derived text: `source:` and `watch:` on `fts5_scope` and `vec_scope` index text
  computed in Ruby and resync when the watched attributes change.
- `vec_scope ..., sync: :manual` with `record.reembed` for apps that run their own
  embedding pipeline.
- Relevance thresholds: `order_by_rank(threshold:)`, and per-arm
  `fts5_threshold:` / `vec_threshold:` on hybrid scopes.
- A reranker can return `[record, score]` pairs, which set each result's
  `<name>_score` to the reranker's score.

[Unreleased]: https://github.com/radioactive-labs/sqlite_search/commits/main
