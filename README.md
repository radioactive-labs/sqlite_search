# sqlite_search

Full-text search for ActiveRecord on SQLite, built directly on [FTS5](https://sqlite.org/fts5.html) virtual
tables. Declare which columns to index, optionally weight them, and get a query scope, prefix search,
BM25-based relevance ranking, and a reindex path — with no triggers and a schema that round-trips cleanly
through `schema.rb`. Vector search (sqlite-vec) and hybrid (FTS5 + vector) search are on the roadmap but not
implemented yet; this gem currently ships FTS5 only.

## Install

```ruby
gem "sqlite_search"
```

## Usage

### 1. Create the FTS5 index in a migration

Use the `create_fts5_table` migration helper (mixed into `ActiveRecord::Migration` automatically in a Rails
app):

```ruby
class CreatePostSearchFts5 < ActiveRecord::Migration[7.1]
  def change
    create_fts5_table :posts, :search, against: { title: 2.0, body: 1.0 }, backfill: true
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

This generates `db/migrate/..._create_search_fts5.rb` calling `create_fts5_table :posts, :search,
against: { title: 2, body: 1 }, backfill: true` (FTS table `posts_search_fts`). Omit `--weights` to index
columns unweighted (a single column becomes `against: :column`, multiple columns become `against: [:a, :b]`).

The second argument (`:search` above) is the **index/scope name** — it determines the FTS table name
(`<table>_<index>_fts`) and the scope you declare on the model. It defaults to `search`; pass `--index` to
choose another (e.g. when a model needs more than one FTS index):

```
rails g sqlite_search:fts5 Post body --index by_body
# => create_fts5_table :posts, :by_body, against: :body   (FTS table posts_by_body_fts)
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

## Limitations

1. **ActiveRecord 8.0+.** The migration helper and its `schema.rb` round-trip rely on `create_virtual_table`,
   which was added in Rails 8.0. The gem does **not** work on 7.1 or 7.2 (verified). This is enforced by the
   gemspec.
2. **SQLite only.** This gem is built directly on SQLite's `FTS5` virtual table module; the SQLite library
   your app links against must have FTS5 compiled in (true of the `sqlite3` gem's bundled SQLite, and of
   most modern system SQLite builds).
2. **Integer primary keys only.** FTS5 virtual tables use `rowid` as their key, and SQLite `rowid` is
   always an integer. Models with a string/UUID primary key cannot be indexed — `fts5_scope`'s sync
   callback raises `SqliteSearch::Error` with a clear message if it ever sees a non-integer primary key,
   rather than letting the write fail with a cryptic `SQLite3::MismatchException` deep in the driver.
3. **Sync is via ActiveRecord `after_*_commit` callbacks, not database triggers.** Anything that changes
   rows without running AR callbacks — `insert_all`, `update_all`, `delete_all`, raw SQL, another
   process/connection writing to the table — will *not* update the FTS5 index. Run `Model.reindex` (or the
   `sqlite_search:reindex` rake task) after any such bulk operation to bring the index back in sync.
4. **Callback-sync failures leave the base row committed.** The sync callback runs in `after_save_commit`,
   i.e. *after* the base record's transaction has already committed. If it raises (e.g. the integer-PK
   guard above), that exception propagates out of `save!`/`create!`, so the call looks like it failed —
   but the base record **is** already saved in the database; only the FTS5 write was skipped/rolled back.
   Callers should not assume a raised exception from `create!`/`update!`/`save!` means nothing was
   persisted, and should treat the index as potentially stale until the next `reindex`.
5. **No database triggers are used.** The FTS5 table is created and modified only via
   `create_virtual_table`/DML executed through Rails migrations and the sync callbacks above, which keeps
   the whole setup representable in and restorable from `schema.rb` — there is nothing hidden in the
   database that a fresh `db:schema:load` would fail to reproduce.
6. **Missing FTS5 table raises a raw SQLite error.** If a scope is queried (or a record is saved) before
   its migration has run, you'll get a plain `no such table: <table>_<scope>_fts` error rather than a
   dedicated actionable one — run the migration (or the `sqlite_search:fts5` generator) to create it. A
   friendlier error here is a planned improvement; it's non-trivial because ActiveRecord 8.1 hides virtual
   tables from `table_exists?`.
