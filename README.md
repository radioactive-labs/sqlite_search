# sqlite_search

Full-text search for ActiveRecord on SQLite, built directly on [FTS5](https://sqlite.org/fts5.html) virtual
tables. Declare which columns to index, optionally weight them, and get a query scope, prefix search,
BM25-based relevance ranking, and a reindex path — with no triggers and a schema that round-trips cleanly
through `schema.rb`. Vector (semantic) search is also available, built on
[sqlite-vec](https://github.com/asg017/sqlite-vec) through the [`neighbor`](https://github.com/ankane/neighbor)
gem, with your app supplying embeddings via a callback. Hybrid (FTS5 + vector) search is still on the
roadmap.

## Install

```ruby
gem "sqlite_search"
```

## Usage

### 1. Create the FTS5 index in a migration

Use the `create_fts5_index` migration helper (mixed into `ActiveRecord::Migration` automatically in a Rails
app):

```ruby
class CreateSearchFts5 < ActiveRecord::Migration[8.0]
  def change
    create_fts5_index :posts, :search, against: { title: 2.0, body: 1.0 }, backfill: true
  end
end
```

- `against:` accepts a single column (`:body`), an array (`[:title, :body]`), or a hash of column => BM25
  weight (`{ title: 2.0, body: 1.0 }`).
- `tokenizer:` defaults to `"porter unicode61"`.
- `backfill: true` seeds the new FTS5 table from existing rows in `table` (off by default, e.g. for a
  brand-new table with no rows yet).
- The resulting virtual table is named `<table>_<name>_fts` (e.g. `posts_search_fts`) and is created with
  `create_virtual_table`, so it shows up in `schema.rb` like any other table.

You can generate this migration instead of writing it by hand:

```
rails g sqlite_search:fts5 Post title body --weights 2,1
```

This generates `db/migrate/..._create_search_fts5.rb` calling `create_fts5_index :posts, :search,
against: { title: 2, body: 1 }, backfill: true` (FTS table `posts_search_fts`). Omit `--weights` to index
columns unweighted (a single column becomes `against: :column`, multiple columns become `against: [:a, :b]`).

The second argument (`:search` above) is the **index/scope name** — it determines the FTS table name
(`<table>_<index>_fts`) and the scope you declare on the model. It defaults to `search`; pass `--index` to
choose another (e.g. when a model needs more than one FTS index):

```
rails g sqlite_search:fts5 Post body --index by_body
# => create_fts5_index :posts, :by_body, against: :body   (FTS table posts_by_body_fts)
```

### 2. Declare the scope on the model

```ruby
class Post < ApplicationRecord
  include SqliteSearch::Model

  fts5_scope :by_body, against: :body
  # or, weighted across multiple columns:
  fts5_scope :search, against: { title: 2.0, body: 1.0 }
end
```

`fts5_scope` defines a named scope on the model and wires up `after_save_commit` / `after_destroy_commit`
callbacks that keep the FTS5 table in sync whenever any of the indexed columns change.

### 3. Query

```ruby
Post.by_body("coffee")                  # sanitized AND-of-terms match
Post.by_body("coffee").where(published: true).order(:created_at) # composes with normal AR scopes
Post.by_body("cof", prefix: true)       # prefix match on the last term
Post.by_body(raw: "coffee OR tea")      # bypass the sanitizer, pass a raw FTS5 MATCH expression
```

A blank/nil query (and a call with no positional query, e.g. `Post.by_body(prefix: true)`) returns an empty
relation (`.none`) rather than matching everything or raising.

User-supplied query strings passed as the positional argument are run through `SqliteSearch::Query`, which
only lets through quoted phrases and alphanumeric/underscore terms (AND-joined), stripping FTS5 operator
syntax — so it's safe to pass raw user input. Use `raw:` only with trusted/internally-built MATCH
expressions.

#### Ranking

```ruby
posts = Post.search("coffee").order_by_rank
posts.first.search_rank # higher is better
```

`order_by_rank` joins the FTS5 table, re-applies the `MATCH`, and orders by SQLite's `bm25()` (inverted, so
higher = more relevant). Each scope also exposes a `<name>_rank` reader (e.g. `search_rank` for a scope
named `:search`) on records loaded via `order_by_rank`, reflecting any per-column weights passed to
`against:`.

### 4. Reindexing

```ruby
Post.reindex(:by_body) # rebuild one named FTS5 index
Post.reindex           # rebuild every fts5_scope defined on the model
```

or from the command line:

```
rake sqlite_search:reindex[Post,by_body]
rake sqlite_search:reindex[Post]   # scope omitted -> rebuild all
```

`reindex` truncates and repopulates the FTS5 table directly from the base table, so it's the recovery path
whenever the index and the base table have drifted (see Limitations below).

## Vector search

Semantic (embedding-based, cosine-similarity) search via [sqlite-vec](https://github.com/asg017/sqlite-vec)
through the [`neighbor`](https://github.com/ankane/neighbor) gem. `sqlite_search` doesn't generate embeddings
itself — your app supplies them via a callback — it stores them in a `vec0` virtual table and gives you a
KNN query scope.

This is optional functionality: add the `neighbor` and `sqlite-vec` gems to your Gemfile before using it.

```ruby
gem "neighbor"
gem "sqlite-vec"
```

### 1. Register an embedder

```ruby
SqliteSearch.embedder do |text, model:, scope:|
  MyEmbeddingClient.embed(text) # returns an Array<Float> matching the scope's `dimensions`
end
```

The block receives the text to embed (the configured `against:` columns joined), the model class, and the
scope name, and must return an `Array<Float>` with exactly `dimensions` elements.

### 2. Create the vec index in a migration

Use the `create_vec_index` migration helper:

```ruby
class CreateSemanticVec < ActiveRecord::Migration[8.0]
  def change
    create_vec_index :posts, :semantic, dimensions: 768
  end
end
```

The resulting virtual table is named `<table>_<index>_vec` (e.g. `posts_semantic_vec`) and is created with
`create_virtual_table`, so it shows up in `schema.rb` like any other table. As with FTS5, you can generate
this migration instead of writing it by hand:

```
rails g sqlite_search:vec Post --index semantic --dimensions 768
```

This generates `db/migrate/..._create_semantic_vec.rb` calling `create_vec_index :posts, :semantic,
dimensions: 768`. `--index` defaults to `semantic`; `--dimensions` is required.

### 3. Declare the scope on the model

```ruby
class Post < ApplicationRecord
  include SqliteSearch::Model

  vec_scope :semantic, against: [:title, :body], dimensions: 768
end
```

`vec_scope` defines a named scope on the model and wires up `after_save_commit` / `after_destroy_commit`
callbacks that keep the vec table in sync whenever any of the `against:` columns change. By default,
embedding happens **asynchronously** via an ActiveJob (`SqliteSearch::EmbedJob`); pass `sync: :inline` to
embed synchronously in the callback instead (also required if your app doesn't use ActiveJob):

```ruby
vec_scope :semantic, against: [:title, :body], dimensions: 768, sync: :inline
```

`SqliteSearch::EmbedJob` runs on ActiveJob's `:default` queue unless you route it elsewhere:

```ruby
SqliteSearch.config.job_queue = :embeddings
```

### 4. Query

```ruby
Post.semantic("query text", k: 20, threshold: 0.3)
Post.semantic("query text").where(published: true) # composes with normal AR scopes (see limitations)
```

- `k:` caps the number of nearest neighbors fetched (default 20).
- `threshold:` (optional) drops hits whose cosine similarity falls below it.
- A blank/nil query returns an empty relation (`.none`) rather than matching everything or raising.
- Records loaded via `.semantic` expose a `<name>_similarity` reader (e.g. `semantic_similarity`), a cosine
  similarity in `[-1, 1]` (higher is more similar).

### 5. Backfilling / re-embedding

```ruby
Post.reembed(:semantic) # re-embed every row for one named vec index
Post.reembed            # re-embed every vec_scope defined on the model
```

or from the command line:

```
rake sqlite_search:reembed[Post,semantic]
```

Run this after `create_vec_index` to embed existing rows (the migration itself does not backfill), or
whenever the vec table and the base table have drifted (e.g. after a bulk update that skipped callbacks).

## Limitations

1. **ActiveRecord 8.0+.** The migration helper and its `schema.rb` round-trip rely on `create_virtual_table`,
   which was added in Rails 8.0. The gem does **not** work on 7.1 or 7.2 (verified). This is enforced by the
   gemspec.
2. **SQLite only.** This gem is built directly on SQLite's `FTS5` virtual table module; the SQLite library
   your app links against must have FTS5 compiled in (true of the `sqlite3` gem's bundled SQLite, and of
   most modern system SQLite builds).
3. **Integer primary keys only.** FTS5 virtual tables use `rowid` as their key, and SQLite `rowid` is
   always an integer. Models with a string/UUID primary key cannot be indexed — `fts5_scope`'s sync
   callback raises `SqliteSearch::Error` with a clear message if it ever sees a non-integer primary key,
   rather than letting the write fail with a cryptic `SQLite3::MismatchException` deep in the driver.
4. **Sync is via ActiveRecord `after_*_commit` callbacks, not database triggers.** Anything that changes
   rows without running AR callbacks — `insert_all`, `update_all`, `delete_all`, raw SQL, another
   process/connection writing to the table — will *not* update the FTS5 index. Run `Model.reindex` (or the
   `sqlite_search:reindex` rake task) after any such bulk operation to bring the index back in sync.
5. **Callback-sync failures leave the base row committed.** The sync callback runs in `after_save_commit`,
   i.e. *after* the base record's transaction has already committed. If it raises (e.g. the integer-PK
   guard above), that exception propagates out of `save!`/`create!`, so the call looks like it failed —
   but the base record **is** already saved in the database; only the FTS5 write was skipped/rolled back.
   Callers should not assume a raised exception from `create!`/`update!`/`save!` means nothing was
   persisted, and should treat the index as potentially stale until the next `reindex`.
6. **No database triggers are used.** The FTS5 table is created and modified only via
   `create_virtual_table`/DML executed through Rails migrations and the sync callbacks above, which keeps
   the whole setup representable in and restorable from `schema.rb` — there is nothing hidden in the
   database that a fresh `db:schema:load` would fail to reproduce.
7. **Missing FTS5 table raises a raw SQLite error.** If a scope is queried (or a record is saved) before
   its migration has run, you'll get a plain `no such table: <table>_<scope>_fts` error rather than a
   dedicated actionable one — run the migration (or the `sqlite_search:fts5` generator) to create it. A
   friendlier error here is a planned improvement; it's non-trivial because ActiveRecord 8.1 hides virtual
   tables from `table_exists?`.
8. **Vector search needs the optional `neighbor` and `sqlite-vec` gems.** Neither is a dependency of
   `sqlite_search` itself; add both to your Gemfile before declaring a `vec_scope`. Note that `sqlite-vec`
   ships prebuilt native extensions and has no gem build for musl-based platforms (e.g. Alpine).
9. **Cosine distance only, in this version.** `vec_scope`/`create_vec_index` only support
   `distance: :cosine`; euclidean and inner-product distance are not exposed and are planned for a future
   release.
10. **Async by default — new rows are not immediately KNN-findable.** Embedding happens in a background
    `SqliteSearch::EmbedJob` by default, so a record saved just now may not show up in `.semantic` results
    until that job runs. Pass `sync: :inline` to `vec_scope` for synchronous embedding (also required if
    your app doesn't use ActiveJob).
11. **`.semantic` is eager, unlike ordinary AR scopes.** Calling it runs the embed call and the KNN query
    immediately, rather than building a lazy relation — so calling it twice embeds (and queries) twice. Be
    careful chaining it inside code that might invoke the scope more than once.
12. **Filtering after `.semantic` narrows the already-retrieved top-k; it does not constrain the ANN
    search.** `Post.semantic("query").where(published: true)` first fetches the `k` nearest neighbors, then
    filters that result set — it will not necessarily return `k` published posts. Raise `k` to compensate
    if you need more results after filtering.
13. **Integer primary keys only.** Same restriction as FTS5 above (see limitation 3) — vec tables use
    `rowid`/an integer primary key column.
