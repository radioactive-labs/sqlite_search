# sqlite_search

[![Gem Version](https://img.shields.io/gem/v/sqlite_search)](https://rubygems.org/gems/sqlite_search)
[![CI](https://github.com/radioactive-labs/sqlite_search/actions/workflows/ci.yml/badge.svg)](https://github.com/radioactive-labs/sqlite_search/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](https://opensource.org/licenses/MIT)

**Full-text, vector, and hybrid search for ActiveRecord, without leaving SQLite.**
Declare which columns are searchable and get a query scope. No search cluster to
run, no second copy of your data to keep in sync.

It covers three kinds of search behind one DSL. Full-text uses SQLite's FTS5
module with BM25 relevance ranking. Vector (semantic) search uses
[sqlite-vec](https://github.com/asg017/sqlite-vec) through the
[`neighbor`](https://github.com/ankane/neighbor) gem, with your app supplying
embeddings via a callback. Hybrid search fuses the two with Reciprocal Rank
Fusion and an optional reranking step. There are no database triggers and no
background service to run. Works on Rails 8.0+.

## 30-second tour

Declare a search index in a migration, add one line to the model, and query it:

```ruby
# db/migrate/xxxx_create_posts_search.rb
class CreatePostsSearch < ActiveRecord::Migration[8.0]
  def change
    create_fts5_index :posts, :search, against: { title: 2.0, body: 1.0 }, backfill: true
  end
end

# app/models/post.rb
class Post < ApplicationRecord
  include SqliteSearch::Model
  fts5_scope :search, against: { title: 2.0, body: 1.0 }
end

# anywhere
Post.search("morning coffee")                    # a normal, chainable relation
Post.search("coffee").order_by_rank.first.search_rank
Post.where(author_id: 7).search("coffee")        # searches only that author's posts
```

The scope is an ordinary `ActiveRecord::Relation`, so it composes with the rest
of your query. User input is sanitized into a safe `MATCH` expression for you, so
you can pass `params[:q]` straight through.

## Installation

Add the gem:

```ruby
gem "sqlite_search"
```

Then `bundle install`. In a Rails app the model concern and the migration
helpers are wired in automatically. Vector and hybrid search need two more gems;
see [Vector search](#vector-search).

## Full-text search

### Create the index in a migration

`create_fts5_index` creates an FTS5 virtual table for a model. It is mixed into
`ActiveRecord::Migration`, so it is available in any migration:

```ruby
create_fts5_index :posts, :search, against: { title: 2.0, body: 1.0 }, backfill: true
```

`against:` takes a single column (`:body`), a list (`[:title, :body]`), or a hash
of column to BM25 weight (`{ title: 2.0, body: 1.0 }`, weighting title matches
higher). `tokenizer:` defaults to `"porter unicode61"`, which folds case and
accents and stems words, so a search for "running" also matches "run".
`backfill: true` seeds the index from rows that already exist; leave it off for a
brand-new table.

The second argument (`:search`) names the index. It becomes the FTS table name
(`posts_search_fts`) and the scope name on the model, so keep the two in step. A
`rails g sqlite_search:fts5` generator writes the migration for you:

```
rails g sqlite_search:fts5 Post title body --weights 2,1
rails g sqlite_search:fts5 Post body --index search_body   # a second index on the same model
```

The virtual table is created with `create_virtual_table`, so it appears in
`schema.rb` and restores cleanly from `db:schema:load`. Nothing is hidden in the
database.

### Declare the scope

```ruby
class Post < ApplicationRecord
  include SqliteSearch::Model
  fts5_scope :search, against: { title: 2.0, body: 1.0 }
end
```

`fts5_scope` defines the `Post.search` scope and wires up `after_save` and
`after_destroy` callbacks that keep the index in step whenever an indexed column
changes. They run inside the transaction, so the index write is atomic with the
row: if it fails, both roll back. A model can declare more than one index
(`fts5_scope :search_body, against: :body`) and each gets its own scope.

### Query

```ruby
Post.search("coffee")                              # AND of the sanitized terms
Post.search("coffee").where(published: true)       # composes with any AR scope
Post.search("cof", prefix: true)                   # prefix match on the last term
Post.search(raw: "coffee OR tea")                  # bypass the sanitizer, pass raw FTS5 syntax
```

A blank or nil query (including a call with no positional argument, such as
`Post.search(prefix: true)`) returns `.none` rather than matching everything or
raising. Any string you pass as the positional argument goes through
`SqliteSearch::Query`, which keeps quoted phrases and alphanumeric terms and
strips FTS5 operator syntax, so untrusted input is safe. Reserve `raw:` for
trusted, internally built expressions.

### Ranking

By default the scope filters but does not order, so it composes with your own
`order`. Ask for relevance ordering explicitly:

```ruby
posts = Post.search("coffee").order_by_rank
posts.first.search_rank   # higher is more relevant
```

`order_by_rank` orders by SQLite's `bm25()`, inverted so higher means better, and
honors the per-column weights from `against:`. Each ranked record carries a
`<name>_rank` reader (`search_rank` for a scope named `:search`).

### Reindexing

Bulk writes that skip callbacks (`insert_all`, `update_all`, raw SQL, another
connection) leave the index stale. Rebuild it from the base table:

```ruby
Post.reindex(:search)   # one index
Post.reindex            # every fts5_scope on the model
```

or `rake sqlite_search:reindex[Post,search]` from the command line.

## Vector search

Semantic search ranks rows by embedding similarity instead of keywords. It uses
[sqlite-vec](https://github.com/asg017/sqlite-vec) through the
[`neighbor`](https://github.com/ankane/neighbor) gem. sqlite_search stores and
queries the vectors; your app produces them. Add both gems, since neither is a
dependency of sqlite_search itself:

```ruby
gem "neighbor"
gem "sqlite-vec"
```

### Register an embedder

sqlite_search calls this block whenever it needs to turn text into a vector, both
when indexing a row and when running a query, so the same model does both sides:

```ruby
SqliteSearch.embedder do |text, model:, scope:|
  MyEmbeddingClient.embed(text)   # returns an Array<Float> of length `dimensions`
end
```

The block receives the text (the `against:` columns joined), the model class, and
the scope name, so you can route to different embedding models per scope if you want.

### Create the index and declare the scope

```ruby
# migration
create_vec_index :posts, :semantic_search, dimensions: 768

# model
vec_scope :semantic_search, against: [:title, :body], dimensions: 768
```

The vector table is `posts_semantic_search_vec`, a `vec0` virtual table that also
round-trips through `schema.rb`. A `rails g sqlite_search:vec Post --index
semantic --dimensions 768` generator writes the migration. `create_vec_index`
does not backfill (there is no text to embed at migration time), so run
`Post.reembed(:semantic_search)` once afterward to embed existing rows.

By default a save enqueues a background `SqliteSearch::EmbedJob` to do the
embedding, so an expensive embedding call stays out of the request. Pass
`sync: :inline` to embed inside the callback instead, which you want when the
embedder is cheap or when your app does not use ActiveJob:

```ruby
vec_scope :semantic_search, against: [:title, :body], dimensions: 768, sync: :inline
```

Route the job to a specific queue with `SqliteSearch.config.job_queue = :embeddings`.

### Query

```ruby
Post.semantic_search("a warm drink to start the day", k: 20, threshold: 0.3)
```

`k:` caps how many nearest neighbors to fetch (default 20). `threshold:` drops
hits below a cosine similarity you set. Each returned record exposes a
`<name>_similarity` reader (a cosine similarity in `[-1, 1]`, higher is closer). A
blank or nil query returns `.none`.

Re-embed after a bulk write the same way you reindex FTS5:

```ruby
Post.reembed(:semantic_search)   # one named vec index
Post.reembed                     # every vec_scope on the model
```

or `rake sqlite_search:reembed[Post,semantic_search]` from the command line.

## Hybrid search

Hybrid search runs the keyword search and the vector search together, as two
"arms", and fuses their rankings, which catches both exact-term matches and
semantic ones. It reuses an `fts5_scope` and a `vec_scope` you have already
declared:

```ruby
class Post < ApplicationRecord
  include SqliteSearch::Model

  fts5_scope :search_body, against: :body
  vec_scope :semantic_search, against: :body, dimensions: 768, sync: :inline
  hybrid_scope :search, fts5: :search_body, vec: :semantic_search
end
```

`fts5:` and `vec:` name the two arms. They must already be declared, or
`hybrid_scope` raises `SqliteSearch::Error` at load time (as it does if the
hybrid name collides with an arm's name). `k:` sets the RRF constant (default
60), which is a different `k:` than the neighbor count on `vec_scope`.

```ruby
posts = Post.search("coffee", limit: 20)
posts.first.search_score   # fused score, higher is better
```

Each arm produces a ranked candidate list, Reciprocal Rank Fusion combines them,
an optional reranker reorders the result, and the top `limit` records come back
as a relation ordered to match, each carrying a `<name>_score` reader. `limit:`
defaults to 20. A blank query returns `.none`. Pass `rerank: false` to skip the
reranker and return the plain fused order.

### Reranking

Register a reranker once and every hybrid scope uses it, unless a call opts out:

```ruby
SqliteSearch.reranker do |query, documents, model:, scope:|
  # documents are the fused candidate records, already loaded, in RRF order.
  # Return them reordered; a subset is fine, unknown records are ignored.
  MyRerankClient.rerank(query, documents)
end
```

`model:` is the model class the scope was declared on, and `scope:` is the hybrid
scope name (the same pair is passed to the embedder block). Reranking is
best-effort: if the block raises, the failure is logged and the search falls back
to the fused order, so a broken reranker never takes down a search.

## Filtering and multi-tenancy

Conditions you chain before the search push into the query as an exact
pre-filter, not a post-filter:

```ruby
Post.where(tenant_id: 5).published.search("coffee")   # pre-filters both arms
Post.where(tenant_id: 5).semantic_search("coffee")           # pre-filters the KNN scan
```

The keyword arm uses the ordinary `WHERE`/`JOIN` SQL that ActiveRecord already
builds for the chained scope. The vector arm joins back to the source table
before the scan runs. That pre-filter is exact rather than approximate, because
`vec0`'s KNN is a brute-force scan to begin with, so folding in your conditions
just narrows what it scans. Concretely,
`Post.where(tenant_id: 5).semantic_search("coffee", k: 10)` returns the 10 nearest
neighbors within tenant 5, not the global top 10 trimmed to tenant 5 afterward.

Chaining a condition after the search is the escape hatch. It post-filters the
result set like any relation:

```ruby
Post.search("coffee").where("created_at > ?", 1.week.ago)
```

Only conditions that have a SQL form against the source table (or tables reached
through `joins`) can be pushed into the pre-filter. A condition that exists only
in Ruby has nothing to push, so it lands as a post-filter, which narrows an
already-fused set; raise `k:` or `limit:` if you need more rows to survive it.

## Limitations and notes

**ActiveRecord 8.0 or newer.** The migration helpers and their `schema.rb`
round-trip rely on `create_virtual_table`, which arrived in Rails 8.0. The gem
does not run on 7.1 or 7.2, and the gemspec enforces that.

**SQLite with FTS5.** The gem builds directly on SQLite's FTS5 module, so the
SQLite library your app links against must have FTS5 compiled in. The `sqlite3`
gem's bundled build has it, as do most modern system builds.

**Integer primary keys only.** FTS5 and `vec0` both key rows by an integer id, so
a model with a string or UUID primary key cannot be indexed. The sync callback
raises a clear `SqliteSearch::Error` in that case rather than letting a cryptic
`SQLite3::MismatchException` surface from deep in the driver.

**Sync runs in ActiveRecord callbacks, not triggers.** Any write that skips
callbacks (`insert_all`, `update_all`, raw SQL, a second connection) leaves the
index stale until you run `reindex` or `reembed`. That is the price of keeping
everything in `schema.rb` with nothing hidden in the database.

**A failed vector sync leaves the row committed; FTS5 does not.** The FTS5 index
syncs inside the transaction, so a failed FTS5 write (for example the integer-PK
guard) rolls the row back with it: index and row stay atomic. The vector index
syncs after commit, because it enqueues a job by default and embedding is an
out-of-band call you do not want holding a transaction open. So if a vector sync
raises, the row is already saved and only the vector write was skipped. Treat a
raised exception from the vector path as "saved, vectors may be stale," and
recover with `reembed`.

**A missing index table raises a plain SQLite error.** Query a scope before its
migration has run and you get `no such table: <table>_<scope>_fts`. Run the
migration or the generator. A friendlier message is on the list; it is awkward
today because ActiveRecord 8.1 hides virtual tables from `table_exists?`.

**Vector search needs `neighbor` and `sqlite-vec`.** Add both to your Gemfile
before declaring a `vec_scope`. `sqlite-vec` ships prebuilt native extensions and
has no build for musl platforms such as Alpine.

**Cosine distance only, for now.** `vec_scope` and `create_vec_index` support
`distance: :cosine`. Euclidean and inner-product distance are planned.

**Embedding is async by default.** A row saved right now may not appear in
`.semantic_search` results until its `EmbedJob` runs. Use `sync: :inline` for immediate
indexing (or if you do not use ActiveJob).

**`.semantic_search` and `.search` are eager.** Unlike an ordinary scope, they run the
embedding call and the queries the moment you call them rather than building a
lazy relation. `.search` does the most work, re-running both arms, the fusion,
and any reranker (possibly a network call) on every invocation, so do not call
either one inside a loop.

**Hybrid's vector arm has no relevance threshold.** A bare `.semantic_search` call takes
`threshold:`, but `hybrid_scope` does not, so the vector arm always feeds its
nearest neighbors into the fusion even for a weak semantic match. Per-arm
thresholds may come later.

**The candidate pool is capped.** A hybrid scope pulls `[limit * 3, 100].min`
candidates from each arm before fusing, so a very large `limit:` still fuses from
at most 100 per arm.

## License

Released under the [MIT License](MIT-LICENSE).
