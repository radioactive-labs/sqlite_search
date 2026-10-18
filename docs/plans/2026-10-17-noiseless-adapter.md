# sqlite_search — noiseless Adapter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Do not stage or commit.** The repo owner commits by hand. Each task ends with a "Checkpoint" step instead of a commit.

**Goal:** Let noiseless apps run on SQLite via `adapter: sqlite`, backed by sqlite_search's FTS5, vec, and hybrid scopes, plus the core options that adapter needs.

**Architecture:** Part A adds public sqlite_search API: FTS5 query options (`operator:`, `phrase:`, `minimum_should_match:`, `columns:`, `order_by_rank(weights:)`), `vec_scope(vector:)`, weighted RRF, and definition lookup helpers. Part B adds an opt-in `require "sqlite_search/noiseless"` that defines `Noiseless::Adapters::Sqlite`. It translates the noiseless AST into those scopes on the resolved ActiveRecord model and returns Elasticsearch-shaped hashes. Unsupported features raise (`unsupported: strict`) or degrade safely (`unsupported: lax`).

**Tech Stack:** Ruby 3.3+ (core), Ruby 4.0 + Rails 8.1 + noiseless ~> 0.8 (adapter), ActiveRecord, SQLite FTS5, sqlite-vec via neighbor, Minitest, Standard.

**User Verification:** NO — proven by the automated suite (Ruby 3.3 matrix for core, Ruby 4.0 noiseless job for the adapter).

**Spec:** `docs/specs/2026-10-17-noiseless-adapter-design.md`

---

## File Structure

```
lib/sqlite_search/query.rb                         # A3: operator/phrase/minimum_should_match/columns (modify)
lib/sqlite_search/fts5.rb                          # NullRank#order_by_rank(weights:) (modify)
lib/sqlite_search/fts5/definition.rb               # bm25 per-query weights (modify)
lib/sqlite_search/vec/definition.rb                # check_dimensions (modify)
lib/sqlite_search/hybrid.rb                        # weighted RRF, own implementation (modify)
lib/sqlite_search/model.rb                         # scope options, vector:, weights, lookups (modify)
lib/sqlite_search/noiseless.rb                     # opt-in entry point (new)
lib/sqlite_search/noiseless_adapter/unsupported.rb # strict/lax policy + NoHits (new)
lib/sqlite_search/noiseless_adapter/response.rb    # ES-shaped response (new)
lib/sqlite_search/noiseless_adapter/text_options.rb# ES text options -> FTS5 options (new)
lib/sqlite_search/noiseless_adapter/translator.rb  # AST -> relation + scorer (new)
lib/sqlite_search/noiseless_adapter/sqlite.rb      # Noiseless::Adapters::Sqlite (new)
gemfiles/noiseless.gemfile                         # bundle with noiseless (new)
.gitignore                                         # ignore gemfiles/*.lock (new)
.github/workflows/ci.yml                           # noiseless job (modify)
README.md                                          # docs (modify)
test/query_test.rb, test/rank_test.rb, test/vec_query_test.rb, test/hybrid_test.rb (modify)
test/definition_lookup_test.rb, test/hybrid_rrf_test.rb (new)
test/noiseless_adapter/helper.rb + *_test.rb (new)
```

The support module is `SqliteSearch::NoiselessAdapter`, never `SqliteSearch::Noiseless`: a constant named `Noiseless` under `SqliteSearch` would shadow the top-level `::Noiseless` for all code inside `module SqliteSearch`.

**Shell shorthands used below** (the adapter needs Ruby 4.0; `frum` is the Ruby manager on this machine):

```bash
# Ruby 3.3 core suite (default bundle)
bundle exec rake test
# Ruby 4.0 + noiseless bundle
R4="env PATH=$HOME/.frum/versions/4.0.7/bin:$PATH BUNDLE_GEMFILE=gemfiles/noiseless.gemfile"
$R4 bundle exec rake test
```

Run single files with `bundle exec ruby -Itest -Ilib test/<file>.rb` (or `$R4 bundle exec ruby -Itest -Ilib ...`), and single tests by adding `-n test_name`.

---

### Task 0: Ruby 4 + noiseless bundle and CI job (feasibility gate)

**Goal:** A second bundle with noiseless that runs the full existing suite green on Ruby 4.0 / Rails 8.1, wired into CI.

**Files:**
- Create: `gemfiles/noiseless.gemfile`
- Create: `.gitignore`
- Modify: `.github/workflows/ci.yml`

**Acceptance Criteria:**
- [ ] `$R4 bundle exec rake test` passes with the existing suite (0 failures, 0 errors)
- [ ] `require "noiseless"` loads alongside sqlite_search in that bundle
- [ ] `bundle exec rake test` (Ruby 3.3 default bundle) is unchanged
- [ ] CI has a `noiseless` job using Ruby 4.0 and the new gemfile

**Verify:** `$R4 bundle exec rake test` → `0 failures, 0 errors`

**Steps:**

- [ ] **Step 1: Install Ruby 4.0.7** (changes the local toolchain only; does not touch the repo)

```bash
frum install 4.0.7
$HOME/.frum/versions/4.0.7/bin/ruby -v
```
Expected: `ruby 4.0.7 ...`

- [ ] **Step 2: Create `gemfiles/noiseless.gemfile`**

```ruby
source "https://rubygems.org"

# The noiseless adapter's bundle. noiseless needs Ruby 4.0+ and Rails 8.1+,
# so it stays out of the gemspec and the main Gemfile.
gemspec path: ".."

gem "noiseless", "~> 0.8"
```

- [ ] **Step 3: Create `.gitignore`**

```
gemfiles/*.lock
```

- [ ] **Step 4: Install and probe**

```bash
R4="env PATH=$HOME/.frum/versions/4.0.7/bin:$PATH BUNDLE_GEMFILE=gemfiles/noiseless.gemfile"
$R4 gem install bundler --conservative
$R4 bundle install
$R4 bundle exec ruby -Ilib -e 'require "active_record"; require "sqlite_search"; require "noiseless"; puts Noiseless::VERSION; p Noiseless::Adapters.method(:lookup)'
```
Expected: prints `0.8.x` and a `#<Method: Noiseless::Adapters.lookup...>`.

- [ ] **Step 5: Run the existing suite on Ruby 4**

Run: `$R4 bundle exec rake test`
Expected: all existing tests pass. **If anything fails here, stop and report the failure to the user before continuing** — the adapter cannot ship until the core suite is green on Ruby 4 / Rails 8.1.

- [ ] **Step 6: Add the CI job** — append to `jobs:` in `.github/workflows/ci.yml`:

```yaml
  noiseless:
    name: "noiseless adapter (Ruby 4.0 / Rails 8.1)"
    runs-on: ubuntu-latest
    env:
      BUNDLE_GEMFILE: gemfiles/noiseless.gemfile
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: "4.0"
      - run: bundle install
      - run: bundle exec rake test
```

- [ ] **Step 7: Checkpoint** — `git status` shows only the three files above (plus the ignored lock). Do not commit.

```json:metadata
{"files": ["gemfiles/noiseless.gemfile", ".gitignore", ".github/workflows/ci.yml"], "verifyCommand": "env PATH=$HOME/.frum/versions/4.0.7/bin:$PATH BUNDLE_GEMFILE=gemfiles/noiseless.gemfile bundle exec rake test", "acceptanceCriteria": ["existing suite green on Ruby 4.0 with noiseless bundled", "noiseless loads alongside sqlite_search", "Ruby 3.3 bundle unchanged", "CI noiseless job added"], "requiresUserVerification": false}
```

---

### Task 1: FTS5 query options in `SqliteSearch::Query`

**Goal:** `Query.build` supports `operator:`, `phrase:`, `minimum_should_match:`, and `columns:` while staying injection-safe.

**Files:**
- Modify: `lib/sqlite_search/query.rb`
- Test: `test/query_test.rb`

**Acceptance Criteria:**
- [ ] `operator: :or` OR-joins terms; unknown operators raise `SqliteSearch::Error`
- [ ] `phrase: true` makes one FTS5 phrase (with `prefix:` → `"..." *`)
- [ ] `minimum_should_match:` follows ES rules (int, negative, percent, negative percent), clamps to `1..terms`, collapses to AND/OR at the ends, expands n-of-m otherwise
- [ ] Expansion over 6 terms raises `SqliteSearch::Query::TooManyTerms` (a `SqliteSearch::Error`)
- [ ] `columns:` wraps the expression as `{"a" "b"} : (expr)`
- [ ] Existing query tests still pass unchanged

**Verify:** `bundle exec ruby -Itest -Ilib test/query_test.rb` → `0 failures, 0 errors`

**Steps:**

- [ ] **Step 1: Write the failing tests** — append inside `class QueryTest` in `test/query_test.rb`:

```ruby
  def test_or_operator_joins_terms_with_or
    assert_equal "hot OR coffee", B.build("hot coffee", operator: :or)
    assert_equal "hot OR coffee", B.build("hot coffee", operator: "or")
  end

  def test_prefix_combines_with_or
    assert_equal "flat OR whi*", B.build("flat whi", operator: :or, prefix: true)
  end

  def test_unknown_operator_raises
    assert_raises(SqliteSearch::Error) { B.build("a", operator: :xor) }
  end

  def test_phrase_joins_every_word_into_one_phrase
    assert_equal '"flat white decaf"', B.build('"flat white" decaf', phrase: true)
  end

  def test_phrase_with_prefix_stars_the_phrase
    assert_equal '"flat whi" *', B.build("flat whi", phrase: true, prefix: true)
  end

  def test_minimum_should_match_expands_combinations
    assert_equal "(a AND b) OR (a AND c) OR (b AND c)", B.build("a b c", minimum_should_match: 2)
  end

  def test_minimum_should_match_accepts_percent_and_negative_forms
    three_of_four = B.build("a b c d", minimum_should_match: 3)
    assert_equal "(a AND b AND c) OR (a AND b AND d) OR (a AND c AND d) OR (b AND c AND d)", three_of_four
    assert_equal three_of_four, B.build("a b c d", minimum_should_match: "75%")
    assert_equal three_of_four, B.build("a b c d", minimum_should_match: -1)
    assert_equal three_of_four, B.build("a b c d", minimum_should_match: "-25%")
    assert_equal three_of_four, B.build("a b c d", minimum_should_match: "3")
  end

  def test_minimum_should_match_collapses_at_the_ends
    assert_equal "a AND b", B.build("a b", minimum_should_match: 2)
    assert_equal "a OR b", B.build("a b", minimum_should_match: 1)
    assert_equal "a AND b", B.build("a b", minimum_should_match: 5)
    assert_equal "a OR b", B.build("a b", minimum_should_match: "10%")
  end

  def test_minimum_should_match_over_cap_raises
    assert_raises(SqliteSearch::Query::TooManyTerms) { B.build("a b c d e f g", minimum_should_match: 3) }
    assert_equal "a AND b AND c AND d AND e AND f AND g", B.build("a b c d e f g", minimum_should_match: 7)
  end

  def test_minimum_should_match_rejects_garbage
    assert_raises(SqliteSearch::Error) { B.build("a b", minimum_should_match: "most") }
  end

  def test_columns_wrap_expression_in_a_column_filter
    assert_equal '{"title" "body"} : (hot AND coffee)', B.build("hot coffee", columns: %w[title body])
    assert_equal "hot AND coffee", B.build("hot coffee", columns: [])
  end

  def test_options_keep_input_sanitized
    assert_equal '{"title"} : (a OR b OR c)', B.build("a NEAR( b* ) OR c", operator: :or, columns: [:title])
  end
```

- [ ] **Step 2: Run to verify failure**

Run: `bundle exec ruby -Itest -Ilib test/query_test.rb`
Expected: FAIL/ERROR with `unknown keyword: :operator` (and similar).

- [ ] **Step 3: Implement** — replace `lib/sqlite_search/query.rb` with:

```ruby
# frozen_string_literal: true

module SqliteSearch
  # Converts free user text into a safe FTS5 MATCH string.
  # Only quoted phrases and term characters (Unicode alphanumerics and
  # underscore; this does NOT strip to ASCII, so accented/non-Latin words
  # like "café" or "日本語" survive) make it through; everything else (FTS5
  # operators, punctuation) is dropped, so untrusted input cannot inject
  # MATCH syntax. Terms are AND-joined unless operator: :or, phrase: true, or
  # minimum_should_match: say otherwise. Returns nil when nothing usable.
  class Query
    # A quoted phrase, or a run of text between quotes. A quote with no partner
    # matches neither and is skipped.
    SEGMENT = /"([^"]*)"|([^"]+)/
    TERM_CHARS = /[^[:alnum:]_]+/
    RESERVED = /\A(?:AND|OR|NOT|NEAR)\z/
    OPERATORS = {and: " AND ", or: " OR "}.freeze
    # minimum_should_match expands to every n-of-m group of terms, which grows
    # combinatorially, so it stops at this many terms.
    MINIMUM_SHOULD_MATCH_TERM_CAP = 6
    MINIMUM_SHOULD_MATCH = /\A(-?)(\d+)(%?)\z/

    class TooManyTerms < SqliteSearch::Error; end

    def self.build(raw, prefix: false, operator: :and, phrase: false, minimum_should_match: nil, columns: nil)
      new(raw, prefix:, operator:, phrase:, minimum_should_match:, columns:).to_match
    end

    def initialize(raw, prefix: false, operator: :and, phrase: false, minimum_should_match: nil, columns: nil)
      @raw = raw.to_s.scrub
      @prefix = prefix
      @joiner = OPERATORS.fetch(operator.to_sym) do
        raise SqliteSearch::Error, "operator must be :and or :or, got #{operator.inspect}"
      end
      @phrase = phrase
      @minimum_should_match = minimum_should_match
      @columns = Array(columns).map(&:to_s)
    end

    def to_match
      tokens = tokenize
      return nil if tokens.empty?

      expression = @phrase ? phrase(tokens) : terms(tokens)
      @columns.empty? ? expression : "#{column_filter} : (#{expression})"
    end

    private

    def terms(tokens)
      tokens[-1] = "#{tokens[-1]}*" if @prefix && !quoted?(tokens[-1])
      return tokens.join(@joiner) unless @minimum_should_match

      required = required_terms(tokens.size)
      return tokens.join(" AND ") if required == tokens.size
      return tokens.join(" OR ") if required == 1
      if tokens.size > MINIMUM_SHOULD_MATCH_TERM_CAP
        raise TooManyTerms, "minimum_should_match over #{MINIMUM_SHOULD_MATCH_TERM_CAP} terms"
      end
      tokens.combination(required).map { |group| "(#{group.join(" AND ")})" }.join(" OR ")
    end

    # Every word, phrases unwrapped, as one FTS5 phrase. Tokens never contain a
    # double quote inside (tokenize splits on them), so this is one string.
    def phrase(tokens)
      text = %("#{tokens.map { |token| token.delete('"') }.join(" ")}")
      @prefix ? "#{text} *" : text
    end

    # Elasticsearch rules: an integer, a negative integer (how many terms may
    # be missing), or a percentage of the terms rounded down; clamped to
    # 1..count.
    def required_terms(count)
      match = MINIMUM_SHOULD_MATCH.match(@minimum_should_match.to_s.strip)
      unless match
        raise SqliteSearch::Error, "minimum_should_match must be an integer or a percentage, got #{@minimum_should_match.inspect}"
      end
      negative, digits, percent = match.captures
      amount = percent.empty? ? digits.to_i : count * digits.to_i / 100
      (negative.empty? ? amount : count - amount).clamp(1, count)
    end

    def column_filter
      "{#{@columns.map { |column| %("#{column.gsub('"', '""')}") }.join(" ")}}"
    end

    # Phrases and words in the order they were typed, so prefix: widens the
    # last thing typed: never a finished word that came before a phrase.
    def tokenize
      @raw.scan(SEGMENT).flat_map do |phrase, text|
        if phrase
          phrase.strip.empty? ? [] : [%("#{phrase.strip}")]
        else
          text.split(TERM_CHARS).reject { |w| w.empty? || w.match?(RESERVED) }
        end
      end
    end

    def quoted?(token)
      token.start_with?('"')
    end
  end
end
```

- [ ] **Step 4: Run to verify pass**

Run: `bundle exec ruby -Itest -Ilib test/query_test.rb`
Expected: `0 failures, 0 errors`

- [ ] **Step 5: Lint** — `bundle exec standardrb lib/sqlite_search/query.rb test/query_test.rb` → no offenses.

- [ ] **Step 6: Checkpoint** — do not commit.

```json:metadata
{"files": ["lib/sqlite_search/query.rb", "test/query_test.rb"], "verifyCommand": "bundle exec ruby -Itest -Ilib test/query_test.rb", "acceptanceCriteria": ["operator: :or joins with OR; unknown raises", "phrase: true builds one phrase, prefix stars it", "minimum_should_match ES rules with clamp and collapse", "expansion over 6 terms raises TooManyTerms", "columns: wraps in column filter", "existing tests pass"], "requiresUserVerification": false}
```

---

### Task 2: FTS5 scope options, per-query bm25 weights, `sqlite_search_fts5_for`

**Goal:** `fts5_scope` calls accept the Task 1 options and `columns:`, `order_by_rank` accepts `weights:`, and models can find the FTS index covering a field list.

**Files:**
- Modify: `lib/sqlite_search/model.rb` (the `fts5_scope` scope lambda, `order_by_rank`, new `sqlite_search_fts5_for`)
- Modify: `lib/sqlite_search/fts5/definition.rb` (`bm25_expression`, new `query_weights`)
- Modify: `lib/sqlite_search/fts5.rb` (`NullRank`)
- Test: `test/rank_test.rb`, `test/definition_lookup_test.rb` (new)

**Acceptance Criteria:**
- [ ] `Post.full("coffee", columns: [:title])` matches only title hits; unknown columns raise `SqliteSearch::Error`
- [ ] `operator:`, `phrase:`, `minimum_should_match:` pass through to `Query.build`
- [ ] `order_by_rank(weights: {body: 1.0})` ranks by those weights; unlisted columns weigh 0; unknown columns raise
- [ ] `.none` from a blank query still chains `order_by_rank(weights:)`
- [ ] `sqlite_search_fts5_for(fields)` picks the covering definition with the fewest columns, ties by declaration order, nil if none

**Verify:** `bundle exec ruby -Itest -Ilib test/rank_test.rb && bundle exec ruby -Itest -Ilib test/definition_lookup_test.rb` → `0 failures, 0 errors`

**Steps:**

- [ ] **Step 1: Write failing tests** — append inside `class RankTest` in `test/rank_test.rb`:

```ruby
  def test_columns_restricts_match_to_listed_columns
    assert_equal [2], @klass.full("coffee", columns: [:title]).pluck(:id)
  end

  def test_columns_rejects_unknown_column
    assert_raises(SqliteSearch::Error) { @klass.full("coffee", columns: [:nope]) }
  end

  def test_operator_or_widens_match
    @klass.create!(id: 3, title: "tea", body: "misc")
    assert_equal [], @klass.full("coffee tea").pluck(:id)
    assert_equal [1, 2, 3], @klass.full("coffee tea", operator: :or).order(:id).pluck(:id)
  end

  def test_minimum_should_match_and_phrase_pass_through
    @klass.create!(id: 3, title: "tea", body: "coffee coffee")
    assert_equal [3], @klass.full("coffee tea juice", minimum_should_match: 2).pluck(:id)
    assert_equal [1, 3], @klass.full("coffee coffee", phrase: true).order(:id).pluck(:id)
  end

  def test_order_by_rank_weights_override_against_weights
    # body weighted alone: row 1 (body "coffee coffee") beats row 2 (title only)
    assert_equal [1, 2], @klass.full("coffee").order_by_rank(weights: {body: 1.0}).pluck(:id)
  end

  def test_order_by_rank_weights_reject_unknown_column
    assert_raises(SqliteSearch::Error) { @klass.full("coffee").order_by_rank(weights: {nope: 1.0}) }
  end

  def test_order_by_rank_weights_safe_on_blank
    assert_equal [], @klass.full("").order_by_rank(weights: {body: 1.0}).to_a
  end
```

Create `test/definition_lookup_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

class DefinitionLookupTest < SqliteSearch::TestCase
  def setup
    ActiveRecord::Base.connection.create_table(:posts, force: true) { |t|
      t.string :title
      t.text :body
    }
    @klass = Class.new(ActiveRecord::Base) do
      self.table_name = "posts"
      include SqliteSearch::Model

      fts5_scope :full, against: {title: 2.0, body: 1.0}
      fts5_scope :titles, against: :title
      fts5_scope :also_titles, against: [:title]
    end
  end

  def teardown
    ActiveRecord::Base.connection.drop_table(:posts, if_exists: true)
  end

  def test_fts5_for_prefers_fewest_columns_then_declaration_order
    assert_equal :titles, @klass.sqlite_search_fts5_for([:title]).name
  end

  def test_fts5_for_needs_every_field_covered
    assert_equal :full, @klass.sqlite_search_fts5_for(%w[title body]).name
    assert_nil @klass.sqlite_search_fts5_for(%w[title summary])
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `bundle exec ruby -Itest -Ilib test/rank_test.rb; bundle exec ruby -Itest -Ilib test/definition_lookup_test.rb`
Expected: errors such as `unknown keyword: :columns` and `undefined method 'sqlite_search_fts5_for'`.

- [ ] **Step 3: Implement `Fts5::Definition` weights** — in `lib/sqlite_search/fts5/definition.rb` replace `bm25_expression` with:

```ruby
      # SQLite bm25() returns lower (more negative) = better. We ORDER BY it
      # ascending, and expose -bm25 as the rank so higher = better. weights:
      # (from order_by_rank) replaces the against: weights for one query.
      def bm25_expression(connection, weights: nil)
        args = [connection.quote_table_name(table_name)]
        column_weights = if weights
          query_weights(connection, weights)
        elsif self.weights
          table_weights(connection)
        end
        args.concat(column_weights.map { |w| format("%g", w) }) if column_weights
        "bm25(#{args.join(", ")})"
      end

      # Per-query weights keyed by FTS column, lined up by table position.
      # Columns left out weigh 0, so they stop contributing to the rank.
      def query_weights(connection, weights)
        by_column = weights.to_h { |column, weight| [column.to_s, Float(weight)] }
        unknown = by_column.keys - column_names
        raise SqliteSearch::Error, "fts5_scope :#{name} has no column(s) #{unknown.join(", ")} to weight." if unknown.any?
        connection.columns(table_name).map { |c| by_column.fetch(c.name, 0.0) }
      end
```

- [ ] **Step 4: Implement `NullRank`** — in `lib/sqlite_search/fts5.rb`:

```ruby
    module NullRank
      def order_by_rank(threshold: nil, weights: nil) = self
    end
```

- [ ] **Step 5: Implement scope options** — in `lib/sqlite_search/model.rb`, inside `fts5_scope`, replace the scope's first two lines and the `order_by_rank` definition:

```ruby
        scope name, ->(query = nil, prefix: false, raw: nil, operator: :and, phrase: false, minimum_should_match: nil, columns: nil) do
          unknown = Array(columns).map(&:to_s) - definition.column_names
          if unknown.any?
            raise SqliteSearch::Error, "fts5_scope :#{definition.name} has no column(s) #{unknown.join(", ")}; its columns are #{definition.column_names.join(", ")}."
          end
          match = raw || SqliteSearch::Query.build(query, prefix:, operator:, phrase:, minimum_should_match:, columns:)
          next none.extending(SqliteSearch::Fts5::NullRank) if match.nil? || match.to_s.empty?
```

and

```ruby
            define_method(:order_by_rank) do |threshold: nil, weights: nil|
              bm25 = with_connection { |conn| definition.bm25_expression(conn, weights: weights) }
```

(the rest of the `order_by_rank` body is unchanged). Then add, right after `sqlite_search_fts5_definitions`:

```ruby
      # The fts5_scope whose against: columns cover every field, preferring the
      # one with the fewest columns, then declaration order. nil when none does.
      def sqlite_search_fts5_for(fields)
        wanted = Array(fields).map(&:to_s)
        sqlite_search_fts5_definitions.values
          .select { |definition| (wanted - definition.column_names).empty? }
          .each_with_index.min_by { |definition, index| [definition.columns.size, index] }
          &.first
      end
```

- [ ] **Step 6: Run to verify pass**

Run: `bundle exec ruby -Itest -Ilib test/rank_test.rb && bundle exec ruby -Itest -Ilib test/definition_lookup_test.rb && bundle exec rake test`
Expected: `0 failures, 0 errors` for all.

- [ ] **Step 7: Lint** — `bundle exec standardrb` → no offenses.

- [ ] **Step 8: Checkpoint** — do not commit.

```json:metadata
{"files": ["lib/sqlite_search/model.rb", "lib/sqlite_search/fts5/definition.rb", "lib/sqlite_search/fts5.rb", "test/rank_test.rb", "test/definition_lookup_test.rb"], "verifyCommand": "bundle exec rake test", "acceptanceCriteria": ["columns: restricts and validates", "operator/phrase/minimum_should_match pass through", "order_by_rank(weights:) with 0 for unlisted, unknown raises", "NullRank accepts weights:", "sqlite_search_fts5_for selection rules"], "requiresUserVerification": false}
```

---

### Task 3: `vec_scope(vector:)` and `sqlite_search_vec_for`

**Goal:** Vec scopes accept a precomputed embedding, and models can look up a vec definition by name.

**Files:**
- Modify: `lib/sqlite_search/model.rb` (vec scope lambda, new `sqlite_search_vec_for`)
- Modify: `lib/sqlite_search/vec/definition.rb` (new `check_dimensions`)
- Test: `test/vec_query_test.rb`, `test/definition_lookup_test.rb`

**Acceptance Criteria:**
- [ ] `Post.semantic(vector: [...])` runs KNN without calling the embedder, honoring `k:`
- [ ] Passing both a query and `vector:` raises `SqliteSearch::Error`
- [ ] A vector of the wrong length raises `SqliteSearch::Error`
- [ ] `sqlite_search_vec_for(name)` returns the definition or nil

**Verify:** `bundle exec ruby -Itest -Ilib test/vec_query_test.rb && bundle exec ruby -Itest -Ilib test/definition_lookup_test.rb` → `0 failures, 0 errors`

**Steps:**

- [ ] **Step 1: Write failing tests** — add `require "minitest/mock"` under `require "test_helper"` in `test/vec_query_test.rb`, then append inside `class VecQueryTest`:

```ruby
  # stub embedder: "morning coffee" -> [1, 0, 0.14], "green tea" -> [0, 1, 0.09]
  def test_vector_queries_without_a_query_string
    assert_equal [1, 2], @klass.semantic(vector: [1.0, 0.0, 0.14]).pluck(:id)
    assert_equal [1], @klass.semantic(vector: [1.0, 0.0, 0.14], k: 1).pluck(:id)
  end

  def test_vector_does_not_call_the_embedder
    definition = @klass.sqlite_search_vec_definitions[:semantic]
    definition.stub(:embed, ->(*) { flunk "embedder called" }) do
      assert_equal 2, @klass.semantic(vector: [0.0, 1.0, 0.09]).first.id
    end
  end

  def test_query_and_vector_together_raise
    assert_raises(SqliteSearch::Error) { @klass.semantic("coffee", vector: [1.0, 0.0, 0.1]) }
  end

  def test_vector_with_wrong_dimensions_raises
    assert_raises(SqliteSearch::Error) { @klass.semantic(vector: [1.0, 0.0]) }
  end
```

Append inside `class DefinitionLookupTest` in `test/definition_lookup_test.rb`, and add the vec scope to its `setup` class body (after the fts5 scopes):

```ruby
      vec_scope :semantic, against: :body, dimensions: 3, sync: :manual
```

```ruby
  def test_vec_for_matches_scope_name
    assert_equal :semantic, @klass.sqlite_search_vec_for("semantic").name
    assert_nil @klass.sqlite_search_vec_for(:nope)
  end
```

- [ ] **Step 2: Run to verify failure**

Run: `bundle exec ruby -Itest -Ilib test/vec_query_test.rb`
Expected: errors with `unknown keyword: :vector`.

- [ ] **Step 3: Implement `check_dimensions`** — add to `lib/sqlite_search/vec/definition.rb` after `embed`:

```ruby
      # A caller-supplied vector (vec scope's vector:) must fit the index.
      def check_dimensions(vector)
        return vector if vector.length == dimensions
        raise SqliteSearch::Error, "vector: has #{vector.length} dimensions for #{model.name}##{name}, expected #{dimensions}."
      end
```

- [ ] **Step 4: Implement the scope** — in `lib/sqlite_search/model.rb`, inside `vec_scope`, replace:

```ruby
        scope name, ->(query = nil, k: 20, threshold: nil) do
          next none if query.nil? || query.to_s.strip.empty?

          vector = definition.embed(query.to_s, record_model: klass)
```

with:

```ruby
        scope name, ->(query = nil, k: 20, threshold: nil, vector: nil) do
          if vector
            raise SqliteSearch::Error, "vec_scope :#{definition.name} takes a query or vector:, not both." unless query.nil?
            vector = definition.check_dimensions(vector)
          else
            next none if query.nil? || query.to_s.strip.empty?
            vector = definition.embed(query.to_s, record_model: klass)
          end
```

and add, right after `sqlite_search_vec_definitions`:

```ruby
      def sqlite_search_vec_for(name) = sqlite_search_vec_definitions[name.to_sym]
```

- [ ] **Step 5: Run to verify pass**

Run: `bundle exec rake test`
Expected: `0 failures, 0 errors`

- [ ] **Step 6: Lint** — `bundle exec standardrb` → no offenses.

- [ ] **Step 7: Checkpoint** — do not commit.

```json:metadata
{"files": ["lib/sqlite_search/model.rb", "lib/sqlite_search/vec/definition.rb", "test/vec_query_test.rb", "test/definition_lookup_test.rb"], "verifyCommand": "bundle exec rake test", "acceptanceCriteria": ["vector: runs KNN without embedder, honors k", "query + vector raises", "wrong dimensions raise", "sqlite_search_vec_for returns definition or nil"], "requiresUserVerification": false}
```

---

### Task 4: Weighted RRF and `hybrid_scope` arm weights

**Goal:** `Hybrid.rrf` takes per-arm weights (own implementation, deterministic ties) and `hybrid_scope` calls accept `fts5_weight:` / `vec_weight:`.

**Files:**
- Modify: `lib/sqlite_search/hybrid.rb` (`rrf`)
- Modify: `lib/sqlite_search/model.rb` (`hybrid_scope` lambda)
- Test: `test/hybrid_rrf_test.rb` (new), `test/hybrid_test.rb`

**Acceptance Criteria:**
- [ ] Default weights give the same scores as `Neighbor::Reranking.rrf`
- [ ] `weights: [2.0, 1.0]` scales each arm's contribution
- [ ] Ties break by first appearance (list a, then list b)
- [ ] Negative, non-finite, or all-zero weights raise `SqliteSearch::Error`
- [ ] `hybrid_scope` passes `fts5_weight:` / `vec_weight:` (default 1.0) to `rrf`

**Verify:** `bundle exec ruby -Itest -Ilib test/hybrid_rrf_test.rb && bundle exec ruby -Itest -Ilib test/hybrid_test.rb` → `0 failures, 0 errors`

**Steps:**

- [ ] **Step 1: Write failing tests** — create `test/hybrid_rrf_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

class HybridRrfTest < SqliteSearch::TestCase
  def test_default_weights_match_neighbor_scores
    a = [1, 2, 3]
    b = [3, 4, 1]
    expected = Neighbor::Reranking.rrf(a.map { |id| {id: id} }, b.map { |id| {id: id} })
      .to_h { |row| [row[:result][:id], row[:score]] }
    fused = SqliteSearch::Hybrid.rrf(a, b)
    assert_equal expected.keys.sort, fused.map(&:first).sort
    fused.each { |id, score| assert_in_delta expected[id], score, 1e-12 }
  end

  def test_weights_scale_each_arm
    assert_equal [[1, 2.0 / 61], [2, 1.0 / 61]], SqliteSearch::Hybrid.rrf([1], [2], weights: [2.0, 1.0])
  end

  def test_ties_break_by_first_appearance
    assert_equal [1, 2], SqliteSearch::Hybrid.rrf([1], [2]).map(&:first)
    assert_equal [2, 1], SqliteSearch::Hybrid.rrf([2], [1]).map(&:first)
  end

  def test_rejects_invalid_weights
    assert_raises(SqliteSearch::Error) { SqliteSearch::Hybrid.rrf([1], [2], weights: [-1.0, 1.0]) }
    assert_raises(SqliteSearch::Error) { SqliteSearch::Hybrid.rrf([1], [2], weights: [0, 0]) }
    assert_raises(SqliteSearch::Error) { SqliteSearch::Hybrid.rrf([1], [2], weights: [Float::INFINITY, 1.0]) }
  end
end
```

Add `require "minitest/mock"` under `require "test_helper"` in `test/hybrid_test.rb`, and append inside `class HybridTest`:

```ruby
  def test_arm_weights_reach_rrf
    seen = nil
    rrf = SqliteSearch::Hybrid.method(:rrf)
    capture = ->(a, b, k:, weights:) {
      seen = weights
      rrf.call(a, b, k: k, weights: weights)
    }
    SqliteSearch::Hybrid.stub(:rrf, capture) { @klass.search("coffee", fts5_weight: 2.0, vec_weight: 0.5) }
    assert_equal [2.0, 0.5], seen
  end
```

- [ ] **Step 2: Run to verify failure**

Run: `bundle exec ruby -Itest -Ilib test/hybrid_rrf_test.rb; bundle exec ruby -Itest -Ilib test/hybrid_test.rb`
Expected: `unknown keyword: :weights` / `unknown keyword: :fts5_weight`.

- [ ] **Step 3: Implement `rrf`** — in `lib/sqlite_search/hybrid.rb` replace `rrf` with:

```ruby
    # Weighted Reciprocal Rank Fusion of two id lists (each already in rank
    # order): score = w_a / (k + rank_a) + w_b / (k + rank_b), ranks 1-based,
    # an absent id contributing 0. Returns [[id, score], ...] by score desc;
    # ties keep first appearance (list a, then list b).
    def rrf(ids_a, ids_b, k: 60, weights: [1.0, 1.0])
      weights = weights.map { |weight| Float(weight) }
      if weights.any? { |weight| !weight.finite? || weight.negative? } || weights.all?(&:zero?)
        raise SqliteSearch::Error, "RRF weights must be finite, non-negative, and not all zero, got #{weights.inspect}."
      end
      scores = Hash.new(0.0)
      [ids_a, ids_b].zip(weights).each do |ids, weight|
        ids.each_with_index { |id, index| scores[id] += weight / (k + index + 1) }
      end
      scores.each_with_index.sort_by { |(_, score), index| [-score, index] }.map(&:first)
    end
```

- [ ] **Step 4: Implement scope weights** — in `lib/sqlite_search/model.rb`, inside `hybrid_scope`:

```ruby
        scope name, ->(query = nil, limit: 20, rerank: true, fts5_threshold: nil, vec_threshold: nil, fts5_weight: 1.0, vec_weight: 1.0) do
```

and

```ruby
          fused = SqliteSearch::Hybrid.rrf(fts_ids, vec_ids, k: rrf_k, weights: [fts5_weight, vec_weight])
```

- [ ] **Step 5: Run to verify pass**

Run: `bundle exec rake test`
Expected: `0 failures, 0 errors` (including the existing hybrid and rerank tests).

- [ ] **Step 6: Lint** — `bundle exec standardrb` → no offenses.

- [ ] **Step 7: Checkpoint** — do not commit.

```json:metadata
{"files": ["lib/sqlite_search/hybrid.rb", "lib/sqlite_search/model.rb", "test/hybrid_rrf_test.rb", "test/hybrid_test.rb"], "verifyCommand": "bundle exec rake test", "acceptanceCriteria": ["default weights match neighbor scores", "weights scale arms", "deterministic tie order", "invalid weights raise", "hybrid_scope passes fts5_weight/vec_weight"], "requiresUserVerification": false}
```

---

### Task 5: Adapter skeleton — entry point, policy, response, filters/sort/pagination, writes

**Goal:** `adapter: sqlite` resolves to a working adapter that answers filter/sort/paginate queries, enforces strict/lax for root options, and no-ops writes.

**Files:**
- Create: `lib/sqlite_search/noiseless.rb`
- Create: `lib/sqlite_search/noiseless_adapter/unsupported.rb`
- Create: `lib/sqlite_search/noiseless_adapter/response.rb`
- Create: `lib/sqlite_search/noiseless_adapter/translator.rb`
- Create: `lib/sqlite_search/noiseless_adapter/sqlite.rb`
- Test: `test/noiseless_adapter/helper.rb`, `test/noiseless_adapter/adapter_test.rb`, `test/noiseless_adapter/response_test.rb`, `test/noiseless_adapter/unsupported_test.rb`

**Acceptance Criteria:**
- [ ] `Noiseless::Adapters.lookup("sqlite")` returns `Noiseless::Adapters::Sqlite`; `unsupported:` accepts `strict`/`lax` as string or symbol, anything else raises `ArgumentError`
- [ ] Scalar, array, and range filters; sort with primary-key tiebreak; offset pagination; totals before pagination; score 1.0
- [ ] Model resolution: AR `model_class` → `register_model` → `index.classify`; otherwise `Noiseless::SearchError`
- [ ] Narrowing root options (`search_after`, `should`, image search, geo filter, non-column filter) raise under strict and return zero hits under lax
- [ ] Decorative root options (aggregations, collapse, pipeline, conversational, joins, remove_duplicates, facet_sample_slope, pinned_hits, non-column sort) raise under strict; under lax they are skipped and logged once
- [ ] Document writes/bulk return `"result" => "noop"` and change nothing; `index_exists?` / `document_exists?` / `cluster.health` work
- [ ] Without noiseless installed (Ruby 3.3 bundle) these tests skip

**Verify:** `$R4 bundle exec ruby -Itest -Ilib -e 'Dir["test/noiseless_adapter/*_test.rb"].each { |f| require File.expand_path(f) }'` → `0 failures, 0 errors`; and `bundle exec rake test` (Ruby 3.3) → adapter tests reported as skips.

**Steps:**

- [ ] **Step 1: Write the test helper** — create `test/noiseless_adapter/helper.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

begin
  require "sqlite_search/noiseless"
rescue LoadError
  # noiseless needs Ruby 4.0+ and Rails 8.1+. These tests run in the
  # "noiseless adapter" CI job (BUNDLE_GEMFILE=gemfiles/noiseless.gemfile).
end

module SqliteSearch
  class NoiselessTestCase < TestCase
    TABLES = %w[posts_text_fts posts_titles_fts posts_semantic_vec posts_nearby_vec posts].freeze

    # Stub embedder (test_helper): [has "coffee", has "tea", length / 100].
    POSTS = [
      {id: 1, title: "Morning coffee", body: "a warm cup to start the day", status: "published", views: 10, tenant_id: 1},
      {id: 2, title: "Green tea", body: "a calm afternoon drink", status: "draft", views: 5, tenant_id: 1},
      {id: 3, title: "Coffee shop guide", body: "where to find good coffee and tea", status: "published", views: 20, tenant_id: 2},
      {id: 4, title: "100% juice_box", body: "orange", status: "published", views: 1, tenant_id: 2}
    ].freeze

    def setup
      skip "noiseless is not installed (BUNDLE_GEMFILE=gemfiles/noiseless.gemfile)" unless defined?(::Noiseless::Adapters::Sqlite)
      @conn = ActiveRecord::Base.connection
      @conn.create_table(:posts, force: true) do |t|
        t.string :title
        t.text :body
        t.string :status
        t.integer :views
        t.integer :tenant_id
      end
      @conn.create_virtual_table("posts_text_fts", "fts5", ["title", "body", "tokenize = 'porter unicode61'"])
      @conn.create_virtual_table("posts_titles_fts", "fts5", ["title", "tokenize = 'porter unicode61'"])
      @conn.create_virtual_table("posts_semantic_vec", "vec0", ["id integer primary key", "embedding float[3] distance_metric=cosine"])
      @conn.create_virtual_table("posts_nearby_vec", "vec0", ["id integer primary key", "embedding float[3] distance_metric=l2"])
      @model = Class.new(ActiveRecord::Base) do
        self.table_name = "posts"
        include SqliteSearch::Model

        fts5_scope :text, against: {title: 2.0, body: 1.0}
        fts5_scope :titles, against: :title
        vec_scope :semantic, against: [:title, :body], dimensions: 3, sync: :inline
        vec_scope :nearby, against: :title, dimensions: 3, distance: :euclidean, sync: :inline
      end
      POSTS.each { |attrs| @model.create!(attrs) }
      @search = Class.new(::Noiseless::Model) { index_name "posts" }
      @adapter = adapter
    end

    def teardown
      TABLES.each { |t| @conn.execute("DROP TABLE IF EXISTS #{@conn.quote_table_name(t)}") } if @conn
    end

    def adapter(**options)
      ::Noiseless::Adapters::Sqlite.new(**options).tap { |a| a.register_model(@model, index_name: "posts") }
    end

    # Builds a query with noiseless's own QueryBuilder and runs it on the
    # adapter, returning a Noiseless::Response::Results.
    def search(adapter = @adapter)
      builder = ::Noiseless::QueryBuilder.new(@search)
      yield builder
      Sync { adapter.search(builder.to_ast, model_class: @search).wait }
    end

    def capture_log
      io = StringIO.new
      original = ActiveRecord::Base.logger
      ActiveRecord::Base.logger = Logger.new(io)
      yield
      io.string
    ensure
      ActiveRecord::Base.logger = original
    end
  end
end
```

- [ ] **Step 2: Write failing tests** — create `test/noiseless_adapter/adapter_test.rb`:

```ruby
# frozen_string_literal: true

require "noiseless_adapter/helper"

class NoiselessAdapterTest < SqliteSearch::NoiselessTestCase
  def test_lookup_by_name_returns_the_sqlite_adapter
    assert_instance_of Noiseless::Adapters::Sqlite, Noiseless::Adapters.lookup("sqlite", hosts: [])
  end

  def test_unsupported_mode_accepts_strings_and_rejects_others
    assert_instance_of Noiseless::Adapters::Sqlite, Noiseless::Adapters::Sqlite.new(unsupported: "lax")
    assert_raises(ArgumentError) { Noiseless::Adapters::Sqlite.new(unsupported: "loose") }
  end

  def test_filters_paginate_and_count_before_paging
    results = search { |q| q.filter(:status, "published").paginate(page: 1, per_page: 2) }
    assert_equal %w[1 3], results.ids
    assert_equal 3, results.total
    assert_equal [1.0, 1.0], results.scores
  end

  def test_second_page
    assert_equal %w[3 4], search { |q| q.paginate(page: 2, per_page: 2) }.ids
  end

  def test_array_and_range_filters
    assert_equal %w[1 2], search { |q| q.filter(:id, [1, 2]) }.ids
    assert_equal %w[1 3], search { |q| q.filter(:views, {gte: 10}) }.ids
    assert_equal %w[2], search { |q| q.filter(:views, {gt: 1, lt: 10}) }.ids
  end

  def test_sort_with_primary_key_tiebreak
    @model.find(4).update!(views: 20)
    assert_equal %w[3 4 1 2], search { |q| q.sort(:views, :desc) }.ids
  end

  def test_sources_carry_the_row
    assert_equal "Morning coffee", search { |q| q.filter(:id, 1) }.sources.first[:title]
  end

  def test_resolves_model_by_index_name_when_unregistered
    adapter = Noiseless::Adapters::Sqlite.new
    error = assert_raises(Noiseless::SearchError) { search(adapter) { |q| q.filter(:id, 1) } }
    assert_match(/no ActiveRecord model for index "posts"/, error.message)
  end

  def test_runs_through_a_named_connection
    Noiseless.connections.register(:sqlite_named, adapter: "sqlite", hosts: [], unsupported: "strict")
    Noiseless.connections.client(:sqlite_named).register_model(@model, index_name: "posts")
    @search.connection(:sqlite_named)
    assert_equal %w[2], @search.new.filter(:status, "draft").execute_sync.ids
  end

  def test_document_writes_are_noops
    Sync do
      assert_equal "noop", @adapter.index_document(index: "posts", id: 1, document: {title: "x"}).wait["result"]
      assert_equal "noop", @adapter.update_document(index: "posts", id: 1, changes: {title: "x"}).wait["result"]
      assert_equal "noop", @adapter.delete_document(index: "posts", id: 1).wait["result"]
      bulk = @adapter.bulk([{index: {_index: "posts", _id: 1, data: {}}}]).wait
      assert_equal({"index" => {"_index" => "posts", "_id" => 1, "result" => "noop"}}, bulk["items"].first)
      refute bulk["errors"]
    end
    assert_equal "Morning coffee", @model.find(1).title
    assert_equal 4, @model.count
  end

  def test_existence_checks_and_health
    Sync do
      assert @adapter.index_exists?("posts").wait
      refute @adapter.index_exists?("nope").wait
      assert @adapter.document_exists?(index: "posts", id: 1).wait
      refute @adapter.document_exists?(index: "posts", id: 99).wait
    end
    assert_equal "green", @adapter.cluster.health["status"]
  end
end
```

Create `test/noiseless_adapter/response_test.rb`:

```ruby
# frozen_string_literal: true

require "noiseless_adapter/helper"

class NoiselessResponseTest < SqliteSearch::NoiselessTestCase
  def test_build_shapes_hits_and_drops_score_columns
    record = @model.select("posts.*, 7.5 AS text_rank").find(1)
    raw = SqliteSearch::NoiselessAdapter::Response.build(
      [record], model: @model, total: 1, scorer: ->(r) { r.text_rank },
      score_columns: ["text_rank"], started: Process.clock_gettime(Process::CLOCK_MONOTONIC)
    )
    hit = raw["hits"]["hits"].first
    assert_equal "posts", hit["_index"]
    assert_equal "1", hit["_id"]
    assert_equal 7.5, hit["_score"]
    assert_equal "Morning coffee", hit["_source"]["title"]
    refute hit["_source"].key?("text_rank")
    assert_equal 7.5, raw["hits"]["max_score"]
    assert_equal({"value" => 1, "relation" => "eq"}, raw["hits"]["total"])
    assert_kind_of Integer, raw["took"]
  end

  def test_empty_response
    raw = SqliteSearch::NoiselessAdapter::Response.empty(started: Process.clock_gettime(Process::CLOCK_MONOTONIC))
    assert_equal 0, raw["hits"]["total"]["value"]
    assert_nil raw["hits"]["max_score"]
    assert_equal [], raw["hits"]["hits"]
  end
end
```

Create `test/noiseless_adapter/unsupported_test.rb`:

```ruby
# frozen_string_literal: true

require "noiseless_adapter/helper"

class NoiselessUnsupportedTest < SqliteSearch::NoiselessTestCase
  NARROWING = {
    "geo filter" => ->(q) { q.geo_distance(:location, lat: 1.0, lon: 2.0, distance: "5km") },
    "search_after" => ->(q) { q.search_after([10, 1]) },
    "non-column filter" => ->(q) { q.filter(:nope, 1) },
    "image search" => ->(q) { q.image_search(:photo, "data") },
    "hash filter value" => ->(q) { q.filter(:status, {near: "x"}) }
  }.freeze

  DECORATIVE = {
    "aggregations" => ->(q) { q.aggregation(:by_status, :terms, field: :status) },
    "collapse" => ->(q) { q.collapse(:status) },
    "pipeline" => ->(q) { q.pipeline("rerank") },
    "conversational" => ->(q) { q.conversational(model_id: "m") },
    "joins" => ->(q) { q.join("authors") },
    "remove_duplicates" => ->(q) { q.remove_duplicates },
    "facet_sample_slope" => ->(q) { q.facet_sample_slope(2) },
    "pinned_hits" => ->(q) { q.pinned_hits({1 => 1}) },
    "non-column sort" => ->(q) { q.sort(:nope) }
  }.freeze

  NARROWING.each do |name, build|
    define_method(:"test_strict_raises_on_#{name.tr(" -", "__")}") do
      error = assert_raises(Noiseless::SearchError) { search { |q| build.call(q) } }
      assert_match(/unsupported: lax/, error.message)
    end

    define_method(:"test_lax_returns_no_hits_on_#{name.tr(" -", "__")}") do
      results = search(adapter(unsupported: :lax)) { |q| build.call(q) }
      assert_equal 0, results.total
      assert_equal [], results.ids
    end
  end

  DECORATIVE.each do |name, build|
    define_method(:"test_strict_raises_on_#{name.tr(" -", "__")}") do
      assert_raises(Noiseless::SearchError) { search { |q| build.call(q) } }
    end

    define_method(:"test_lax_skips_and_logs_#{name.tr(" -", "__")}") do
      results = nil
      log = capture_log { results = search(adapter(unsupported: :lax)) { |q| build.call(q) } }
      assert_equal %w[1 2 3 4], results.ids
      assert_match(/skipped unsupported/, log)
    end
  end

  def test_lax_logs_every_skip_in_one_line
    log = capture_log do
      search(adapter(unsupported: :lax)) { |q| q.collapse(:status).pipeline("p") }
    end
    assert_equal 1, log.lines.grep(/skipped unsupported/).size
    assert_match(/collapse.*pipeline/, log)
  end
end
```

- [ ] **Step 3: Run to verify failure**

Run: `$R4 bundle exec ruby -Itest -Ilib test/noiseless_adapter/adapter_test.rb`
Expected: every test SKIPS with "noiseless is not installed" (because `sqlite_search/noiseless` does not exist yet, the `LoadError` is swallowed). That is the expected red state.

- [ ] **Step 4: Create the entry point** — `lib/sqlite_search/noiseless.rb`:

```ruby
# frozen_string_literal: true

# Opt-in noiseless integration: `require "sqlite_search/noiseless"` defines
# Noiseless::Adapters::Sqlite, which `adapter: sqlite` in config/noiseless.yml
# resolves to. Not loaded by `require "sqlite_search"`.
require "noiseless"
require "sqlite_search"
require "sqlite_search/noiseless_adapter/unsupported"
require "sqlite_search/noiseless_adapter/response"
require "sqlite_search/noiseless_adapter/translator"
require "sqlite_search/noiseless_adapter/sqlite"
```

- [ ] **Step 5: Create the policy** — `lib/sqlite_search/noiseless_adapter/unsupported.rb`:

```ruby
# frozen_string_literal: true

module SqliteSearch
  module NoiselessAdapter
    # Raised during translation when the query can match nothing, so the
    # adapter answers with an empty response. Translation never continues with
    # a .none relation: the vec scope rebuilds its pre-filter from
    # all.only(:where, :joins), which drops none and would widen the search.
    class NoHits < StandardError; end

    # Per-query policy for AST features SQLite cannot honor. :strict raises.
    # :lax answers a narrowing feature (one whose omission would widen the
    # results) with no hits, and skips a decorative one, recording it so the
    # adapter can log what it ignored.
    class Unsupported
      MODES = %i[strict lax].freeze

      def self.mode(value)
        mode = value.to_s.to_sym
        return mode if MODES.include?(mode)
        raise ArgumentError, "unsupported: must be strict or lax, got #{value.inspect}"
      end

      attr_reader :skipped

      def initialize(mode)
        @mode = mode
        @skipped = []
      end

      def narrowing!(what)
        refuse!(what, "answer with no hits")
        raise NoHits
      end

      def decorative(what)
        refuse!(what, "skip it")
        @skipped << what
      end

      private

      def refuse!(what, lax_behavior)
        return if @mode == :lax
        raise Noiseless::SearchError, "the sqlite adapter does not support #{what} (set unsupported: lax on the connection to #{lax_behavior})"
      end
    end
  end
end
```

- [ ] **Step 6: Create the response builder** — `lib/sqlite_search/noiseless_adapter/response.rb`:

```ruby
# frozen_string_literal: true

module SqliteSearch
  module NoiselessAdapter
    # Elasticsearch-shaped search response, the format Noiseless::ResponseFactory reads.
    module Response
      module_function

      def build(records, model:, total:, scorer:, score_columns:, started:)
        hits = records.map do |record|
          {
            "_index" => model.table_name,
            "_id" => record.id.to_s,
            "_score" => scorer.call(record),
            "_source" => record.as_json(except: score_columns)
          }
        end
        envelope(hits, total, started)
      end

      def empty(started:) = envelope([], 0, started)

      def envelope(hits, total, started)
        {
          "took" => ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round,
          "timed_out" => false,
          "_shards" => {"total" => 1, "successful" => 1, "skipped" => 0, "failed" => 0},
          "hits" => {
            "total" => {"value" => total, "relation" => "eq"},
            "max_score" => hits.map { |hit| hit["_score"] }.max,
            "hits" => hits
          }
        }
      end
    end
  end
end
```

- [ ] **Step 7: Create the translator** — `lib/sqlite_search/noiseless_adapter/translator.rb`. Must clauses, vector and hybrid are refused here and replaced in Tasks 6 and 7:

```ruby
# frozen_string_literal: true

module SqliteSearch
  module NoiselessAdapter
    # Turns a noiseless AST into an ActiveRecord relation over one model, plus
    # how to score each returned record. Filters run first so they pre-filter
    # every arm (text, KNN, hybrid).
    class Translator
      Result = Struct.new(:relation, :scorer, :score_columns, :cap, :relevance, keyword_init: true)
      CONSTANT_SCORE = ->(_record) { 1.0 }
      RANGE_OPERATORS = {gte: :gteq, lte: :lteq, gt: :gt, lt: :lt}.freeze

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

      # Replaced in Task 6.
      def apply_musts(relation, nodes)
        nodes.each { |node| @unsupported.narrowing!("#{node.class.name.demodulize} query") }
        [relation, []]
      end

      # Replaced in Task 6.
      def ranked(relation, _definition, _text) = relation

      # Replaced in Task 7.
      def vector(_relation, _node) = @unsupported.narrowing!("vector search")

      # Replaced in Task 7.
      def hybrid(_relation, _node) = @unsupported.narrowing!("hybrid search")

      # An explicit sort replaces relevance order; the primary key breaks ties.
      # With no usable sort, relevance order stands, else primary key order.
      def apply_sort(relation, nodes, relevance:)
        orders = []
        nodes.each do |node|
          field = node.field.to_s
          if @model.columns_hash.key?(field)
            orders << {field => (node.direction.to_s.casecmp?("desc") ? :desc : :asc)}
          else
            @unsupported.decorative("sort on non-column field #{field}")
          end
        end
        return relation if orders.empty? && relevance

        primary_key = @model.primary_key
        orders << {primary_key => :asc} unless orders.any? { |order| order.key?(primary_key) }
        relation.reorder(*orders)
      end

      def where_range(relation, column, bounds)
        bounds.reduce(relation) do |rel, (operator, value)|
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
```

- [ ] **Step 8: Create the adapter** — `lib/sqlite_search/noiseless_adapter/sqlite.rb`:

```ruby
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
```

Note: `unsupported` is a local assigned inside the method body; in the `rescue NoHits` clause it is in scope (method-level rescue). If `NoHits` could be raised before assignment it would be `nil` — it cannot, because only the translator raises it.

- [ ] **Step 9: Run to verify pass**

Run:
```bash
$R4 bundle exec ruby -Itest -Ilib -e 'Dir["test/noiseless_adapter/*_test.rb"].each { |f| require File.expand_path(f) }'
```
Expected: `0 failures, 0 errors, 0 skips`.

If `test_lookup_by_name_returns_the_sqlite_adapter` fails with `undefined method 'lookup'`, the `module Adapters` in `sqlite.rb` was opened before noiseless's autoload of `Noiseless::Adapters` ran. Fix by referencing the constant first at the top of `sqlite.rb`: add `Noiseless::Adapters # autoload noiseless's namespace before reopening it` above `module Noiseless`.

- [ ] **Step 10: Run the Ruby 3.3 suite** — `bundle exec rake test` → `0 failures, 0 errors`, with the adapter tests shown as skips.

- [ ] **Step 11: Lint** — `bundle exec standardrb` → no offenses.

- [ ] **Step 12: Checkpoint** — do not commit.

```json:metadata
{"files": ["lib/sqlite_search/noiseless.rb", "lib/sqlite_search/noiseless_adapter/unsupported.rb", "lib/sqlite_search/noiseless_adapter/response.rb", "lib/sqlite_search/noiseless_adapter/translator.rb", "lib/sqlite_search/noiseless_adapter/sqlite.rb", "test/noiseless_adapter/helper.rb", "test/noiseless_adapter/adapter_test.rb", "test/noiseless_adapter/response_test.rb", "test/noiseless_adapter/unsupported_test.rb"], "verifyCommand": "env PATH=$HOME/.frum/versions/4.0.7/bin:$PATH BUNDLE_GEMFILE=gemfiles/noiseless.gemfile bundle exec rake test", "acceptanceCriteria": ["lookup resolves sqlite adapter; mode validation", "filters/sort/pagination/totals", "model resolution order and error", "narrowing options strict raise / lax zero hits", "decorative options strict raise / lax skip + one log line", "no-op writes, existence checks, health", "skips on Ruby 3.3 bundle"], "requiresUserVerification": false}
```

---

### Task 6: Text queries — ES options, FTS5 with ranking, LIKE fallback, wildcard/prefix/range

**Goal:** `match`, `multi_match`, `combined_fields`, `wildcard`, `prefix`, and `range` translate per spec B3/B4.

**Files:**
- Create: `lib/sqlite_search/noiseless_adapter/text_options.rb`
- Modify: `lib/sqlite_search/noiseless.rb` (require text_options before translator)
- Modify: `lib/sqlite_search/noiseless_adapter/translator.rb` (replace `apply_musts` and `ranked`; add text helpers)
- Test: `test/noiseless_adapter/text_test.rb`

**Acceptance Criteria:**
- [ ] A covering `fts5_scope` serves the clause, restricted to the listed columns, ES default operator OR; a single FTS clause scores by `<name>_rank`
- [ ] `operator`, `type` (best/most/cross_fields, phrase, phrase_prefix, bool_prefix), `^boost`, `minimum_should_match`, `zero_terms_query` honored
- [ ] `minimum_should_match` over 6 terms: strict raises, lax falls back to AND
- [ ] `fuzziness` and unknown options: strict raises, lax skips; `boost`/`tie_breaker`/`analyzer`/`lenient`/`auto_generate_synonyms_phrase_query` silently ignored
- [ ] No covering index → `LIKE` on text columns (score 1.0); non-text fields only → narrowing
- [ ] `wildcard` / `prefix` use escaped `LIKE`; `range` must uses comparisons
- [ ] Several text clauses AND together and score 1.0

**Verify:** `$R4 bundle exec ruby -Itest -Ilib test/noiseless_adapter/text_test.rb` → `0 failures, 0 errors`

**Steps:**

- [ ] **Step 1: Write failing tests** — create `test/noiseless_adapter/text_test.rb`:

```ruby
# frozen_string_literal: true

require "noiseless_adapter/helper"

class NoiselessTextTest < SqliteSearch::NoiselessTestCase
  def test_match_uses_covering_fts_index_with_rank_scores
    results = search { |q| q.match(:title, "coffee") }
    assert_equal %w[1 3], results.ids.sort
    assert results.scores.all?(&:positive?)
    assert_equal results.scores.sort.reverse, results.scores
  end

  def test_match_defaults_to_or_like_elasticsearch
    assert_equal %w[1 2 3], search { |q| q.match(:title, "coffee tea") }.ids.sort
  end

  def test_multi_match_operator_and
    assert_equal %w[3], search { |q| q.multi_match("coffee tea", %w[title body], operator: "and") }.ids
  end

  def test_multi_match_restricts_to_listed_columns
    assert_equal %w[2], search { |q| q.multi_match("tea", ["title"]) }.ids
    assert_equal %w[3], search { |q| q.multi_match("tea", ["body"]) }.ids
  end

  def test_combined_fields_operator
    assert_equal %w[3], search { |q| q.combined_fields("coffee tea", %w[title body], operator: "and") }.ids
  end

  def test_phrase_types
    assert_equal %w[3], search { |q| q.multi_match("coffee and tea", ["body"], type: "phrase") }.ids
    assert_equal [], search { |q| q.multi_match("tea and coffee", ["body"], type: "phrase") }.ids
    assert_equal %w[3], search { |q| q.multi_match("coffee and te", ["body"], type: "phrase_prefix") }.ids
    assert_equal %w[1 3], search { |q| q.multi_match("coff", ["title"], type: "bool_prefix") }.ids.sort
    assert_equal %w[1 2 3], search { |q| q.multi_match("coffee tea", %w[title body], type: "cross_fields") }.ids.sort
  end

  def test_field_boosts_set_per_query_weights
    assert_equal "3", search { |q| q.multi_match("coffee", ["title^0", "body^1"]) }.ids.first
  end

  def test_minimum_should_match
    assert_equal %w[3], search { |q| q.multi_match("coffee tea orange", %w[title body], minimum_should_match: 2) }.ids
  end

  def test_minimum_should_match_over_cap
    query = "coffee tea guide shop where find good"
    assert_raises(Noiseless::SearchError) do
      search { |q| q.multi_match(query, %w[title body], minimum_should_match: 2) }
    end
    lax = search(adapter(unsupported: :lax)) { |q| q.multi_match(query, %w[title body], minimum_should_match: 2) }
    assert_equal %w[3], lax.ids
  end

  def test_zero_terms_query
    assert_equal [], search { |q| q.multi_match("!!!", ["title"]) }.ids
    assert_equal 4, search { |q| q.multi_match("!!!", ["title"], zero_terms_query: "all") }.total
  end

  def test_fuzziness_strict_raises_lax_ignores
    assert_raises(Noiseless::SearchError) { search { |q| q.multi_match("coffee", ["title"], fuzziness: "AUTO") } }
    lax = search(adapter(unsupported: :lax)) { |q| q.multi_match("coffee", ["title"], fuzziness: "AUTO") }
    assert_equal %w[1 3], lax.ids.sort
  end

  def test_scoring_only_options_are_ignored
    assert_equal %w[1 3], search { |q| q.multi_match("coffee", ["title"], boost: 2, tie_breaker: 0.3) }.ids.sort
  end

  def test_like_fallback_on_uncovered_text_column
    results = search { |q| q.match(:status, "publish") }
    assert_equal %w[1 3 4], results.ids
    assert_equal [1.0, 1.0, 1.0], results.scores
  end

  def test_like_fallback_on_non_text_field_is_narrowing
    assert_raises(Noiseless::SearchError) { search { |q| q.match(:views, "10") } }
    assert_equal [], search(adapter(unsupported: :lax)) { |q| q.match(:views, "10") }.ids
  end

  def test_wildcard_and_prefix_escape_like_characters
    assert_equal %w[4], search { |q| q.wildcard(:title, "100%*") }.ids
    assert_equal %w[4], search { |q| q.wildcard(:title, "*_box") }.ids
    assert_equal [], search { |q| q.wildcard(:title, "*x_box") }.ids
    assert_equal %w[3], search { |q| q.prefix(:title, "Coff") }.ids
  end

  def test_range_must
    assert_equal %w[1 3], search { |q| q.range(:views, gte: 10) }.ids
  end

  def test_text_and_filter_combine
    assert_equal %w[1], search { |q| q.match(:title, "coffee").filter(:tenant_id, 1) }.ids
  end

  def test_two_text_clauses_and_together_with_constant_score
    results = search { |q| q.match(:title, "coffee").match(:body, "tea") }
    assert_equal %w[3], results.ids
    assert_equal [1.0], results.scores
  end

  def test_explicit_sort_overrides_rank
    assert_equal %w[3 1], search { |q| q.match(:title, "coffee").sort(:views, :desc) }.ids
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `$R4 bundle exec ruby -Itest -Ilib test/noiseless_adapter/text_test.rb`
Expected: failures with `the sqlite adapter does not support Match query` (the Task 5 refusal).

- [ ] **Step 3: Create `TextOptions`** — `lib/sqlite_search/noiseless_adapter/text_options.rb`:

```ruby
# frozen_string_literal: true

module SqliteSearch
  module NoiselessAdapter
    # Maps Elasticsearch multi_match / combined_fields fields and options onto
    # sqlite_search's FTS5 query options. Defaults follow Elasticsearch: terms
    # are OR-ed unless operator: "and".
    class TextOptions
      TYPES = {
        "best_fields" => {}, "most_fields" => {}, "cross_fields" => {},
        "phrase" => {phrase: true},
        "phrase_prefix" => {phrase: true, prefix: true},
        "bool_prefix" => {prefix: true}
      }.freeze
      # Options that only shape Elasticsearch scoring or analysis.
      IGNORED = %i[boost tie_breaker analyzer auto_generate_synonyms_phrase_query lenient].freeze

      attr_reader :columns, :weights, :query_options, :zero_terms_all

      def initialize(fields, options, unsupported)
        boosts = Array(fields).to_h do |field|
          name, boost = field.to_s.split("^", 2)
          [name, boost && Float(boost)]
        end
        @columns = boosts.keys
        @weights = boosts.transform_values { |boost| boost || 1.0 } if boosts.values.any?
        @query_options = {operator: :or}
        @zero_terms_all = false
        options.each { |key, value| apply(key.to_sym, value, unsupported) }
      end

      private

      def apply(key, value, unsupported)
        case key
        when :operator then @query_options[:operator] = value.to_s.downcase.to_sym
        when :minimum_should_match then @query_options[:minimum_should_match] = value
        when :zero_terms_query then @zero_terms_all = value.to_s == "all"
        when :type
          if TYPES.key?(value.to_s)
            @query_options.merge!(TYPES[value.to_s])
          else
            unsupported.decorative("multi_match type #{value.inspect}")
          end
        when *IGNORED then nil
        else unsupported.decorative("text option #{key}")
        end
      end
    end
  end
end
```

- [ ] **Step 4: Require it** — in `lib/sqlite_search/noiseless.rb`, add above the translator require:

```ruby
require "sqlite_search/noiseless_adapter/text_options"
```

- [ ] **Step 5: Replace `apply_musts` and `ranked`** in `translator.rb` (delete the two "Replaced in Task 6" methods) with:

```ruby
      def apply_musts(relation, nodes)
        text_clauses = []
        nodes.each do |node|
          relation = case node
          when Noiseless::AST::Match
            text_clause(relation, node.value, [node.field], {}, text_clauses)
          when Noiseless::AST::MultiMatch, Noiseless::AST::CombinedFields
            text_clause(relation, node.query, node.fields, node.options, text_clauses)
          when Noiseless::AST::Wildcard
            pattern = @model.sanitize_sql_like(node.value.to_s).tr("*", "%").tr("?", "_")
            where_like(relation, column!(node.field, "wildcard"), pattern)
          when Noiseless::AST::Prefix
            where_like(relation, column!(node.field, "prefix"), "#{@model.sanitize_sql_like(node.value.to_s)}%")
          when Noiseless::AST::Range
            where_range(relation, column!(node.field, "range"), {gte: node.gte, lte: node.lte, gt: node.gt, lt: node.lt}.compact)
          else
            @unsupported.narrowing!("#{node.class.name.demodulize} query")
          end
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

      # A covering fts5_scope serves the clause (and is remembered for
      # ranking); otherwise LIKE on the text columns stands in.
      def text_clause(relation, query, fields, options, text_clauses)
        text = TextOptions.new(fields, options, @unsupported)
        if SqliteSearch::Query.build(query).nil?
          return relation if text.zero_terms_all
          raise NoHits
        end
        definition = @model.sqlite_search_fts5_for(text.columns)
        return like_text(relation, query, text) unless definition

        text_clauses << [definition, text]
        fts(relation, definition, query, text)
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
      # phrase, and every term for minimum_should_match (a subset of the
      # correct results, never a superset).
      def like_text(relation, query, text)
        columns = text.columns.select { |column| %i[string text].include?(@model.columns_hash[column]&.type) }
        @unsupported.narrowing!("text match on non-text fields #{text.columns.join(", ")}") if columns.empty?
        options = text.query_options
        terms = options[:phrase] ? [query.to_s.strip] : query.to_s.scrub.split(/[^[:alnum:]_]+/).reject(&:empty?)
        raise NoHits if terms.empty?

        joiner = (options[:operator] == :or && !options[:minimum_should_match]) ? " OR " : " AND "
        any_column = "(#{columns.map { |column| "#{qualified(column)} LIKE ? ESCAPE '\\'" }.join(" OR ")})"
        binds = terms.flat_map { |term| ["%#{@model.sanitize_sql_like(term)}%"] * columns.size }
        relation.where(terms.map { any_column }.join(joiner), *binds)
      end

      def where_like(relation, column, pattern)
        relation.where("#{qualified(column)} LIKE ? ESCAPE '\\'", pattern)
      end

      # Table-qualified: a ranked relation joins the FTS table, which has
      # columns of the same names.
      def qualified(column)
        @model.with_connection { |conn| "#{@model.quoted_table_name}.#{conn.quote_column_name(column)}" }
      end
```

- [ ] **Step 6: Run to verify pass**

Run: `$R4 bundle exec ruby -Itest -Ilib test/noiseless_adapter/text_test.rb`
Expected: `0 failures, 0 errors`.

If `test_match_uses_covering_fts_index_with_rank_scores` reports an "ambiguous column name" error, a clause is emitting an unqualified column; every raw SQL column must go through `qualified`.

- [ ] **Step 7: Full suites** — `$R4 bundle exec rake test` and `bundle exec rake test` → `0 failures, 0 errors` (the Task 5 unsupported tests still pass).

- [ ] **Step 8: Lint** — `bundle exec standardrb` → no offenses.

- [ ] **Step 9: Checkpoint** — do not commit.

```json:metadata
{"files": ["lib/sqlite_search/noiseless_adapter/text_options.rb", "lib/sqlite_search/noiseless.rb", "lib/sqlite_search/noiseless_adapter/translator.rb", "test/noiseless_adapter/text_test.rb"], "verifyCommand": "env PATH=$HOME/.frum/versions/4.0.7/bin:$PATH BUNDLE_GEMFILE=gemfiles/noiseless.gemfile bundle exec rake test", "acceptanceCriteria": ["covering fts5_scope with columns and default OR; rank score", "operator/type/boost/msm/zero_terms honored", "msm over cap strict raise / lax AND", "fuzziness/unknown strict raise / lax skip; scoring-only options ignored", "LIKE fallback; non-text narrowing", "escaped wildcard/prefix; range must", "multiple text clauses AND with constant score"], "requiresUserVerification": false}
```

---

### Task 7: Vector and hybrid queries

**Goal:** `vector`/`knn` runs the named `vec_scope` with the caller's embedding, and `hybrid` fuses an FTS arm and a vec arm with weighted RRF.

**Files:**
- Modify: `lib/sqlite_search/noiseless_adapter/translator.rb` (replace `vector` and `hybrid`; add helpers)
- Test: `test/noiseless_adapter/vector_test.rb`

**Acceptance Criteria:**
- [ ] KNN results nearest first, `total` capped at `k`, cosine score = similarity, euclidean score = `1/(1+d)`
- [ ] Filters and musts pre-filter the KNN
- [ ] Missing vec scope, distance mismatch, `inner_product`, wrong dimensions raise `Noiseless::SearchError` in both modes
- [ ] Hybrid fuses with `text_weight`/`vector_weight`; weights change the winner
- [ ] Hybrid without a covering FTS index, or with empty fields on a model with several fts5 scopes, raises
- [ ] Hybrid respects filters

**Verify:** `$R4 bundle exec ruby -Itest -Ilib test/noiseless_adapter/vector_test.rb` → `0 failures, 0 errors`

**Steps:**

- [ ] **Step 1: Write failing tests** — create `test/noiseless_adapter/vector_test.rb`:

```ruby
# frozen_string_literal: true

require "noiseless_adapter/helper"

class NoiselessVectorTest < SqliteSearch::NoiselessTestCase
  COFFEE = [1.0, 0.0, 0.4].freeze

  def test_knn_nearest_first_with_similarity_scores
    results = search { |q| q.vector(:semantic, COFFEE, k: 2) }
    assert_equal %w[1 3], results.ids
    assert_operator results.scores.first, :>, results.scores.last
    assert_operator results.scores.first, :<=, 1.0
    assert_equal 2, results.total
  end

  def test_filters_prefilter_the_knn
    assert_equal %w[3], search { |q| q.filter(:tenant_id, 2).vector(:semantic, COFFEE, k: 1) }.ids
  end

  def test_text_must_prefilters_the_knn
    assert_equal %w[3], search { |q| q.match(:body, "tea").vector(:semantic, COFFEE, k: 3) }.ids
  end

  def test_euclidean_scores
    results = search { |q| q.vector(:nearby, [1.0, 0.0, 0.14], k: 1, distance_metric: :l2) }
    assert_equal %w[1], results.ids
    assert_in_delta 1.0, results.scores.first, 1e-6
  end

  def test_configuration_errors_raise_even_when_lax
    lax = adapter(unsupported: :lax)
    assert_raises(Noiseless::SearchError) { search(lax) { |q| q.vector(:nope, COFFEE) } }
    assert_raises(Noiseless::SearchError) { search(lax) { |q| q.vector(:nearby, COFFEE, k: 1) } }
    assert_raises(Noiseless::SearchError) { search(lax) { |q| q.vector(:semantic, COFFEE, distance_metric: :inner_product) } }
    assert_raises(Noiseless::SearchError) { search(lax) { |q| q.vector(:semantic, [1.0, 0.0]) } }
  end

  def test_hybrid_fuses_both_arms
    results = search { |q| q.hybrid("tea", COFFEE, field: :semantic, fields: %w[title body], k: 3) }
    assert_operator results.total, :>, 0
    assert_operator results.total, :<=, 3
    assert_equal results.scores.sort.reverse, results.scores
  end

  def test_hybrid_weights_pick_the_winning_arm
    text_only = search { |q| q.hybrid("tea", COFFEE, field: :semantic, fields: %w[title body], text_weight: 1.0, vector_weight: 0.0, k: 3) }
    vector_only = search { |q| q.hybrid("tea", COFFEE, field: :semantic, fields: %w[title body], text_weight: 0.0, vector_weight: 1.0, k: 3) }
    assert_equal "2", text_only.ids.first
    assert_equal "1", vector_only.ids.first
  end

  def test_hybrid_needs_a_covering_text_index
    assert_raises(Noiseless::SearchError) { search { |q| q.hybrid("tea", COFFEE, field: :semantic, fields: ["status"]) } }
  end

  def test_hybrid_without_fields_needs_a_single_fts5_scope
    assert_raises(Noiseless::SearchError) { search { |q| q.hybrid("tea", COFFEE, field: :semantic) } }
  end

  def test_hybrid_respects_filters
    ids = search { |q| q.filter(:tenant_id, 1).hybrid("tea", COFFEE, field: :semantic, fields: %w[title body], k: 4) }.ids
    assert_empty ids - %w[1 2]
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `$R4 bundle exec ruby -Itest -Ilib test/noiseless_adapter/vector_test.rb`
Expected: failures with `does not support vector search`.

- [ ] **Step 3: Implement** — in `translator.rb`, add constants next to `RANGE_OPERATORS`:

```ruby
      VECTOR_DISTANCES = {cosine: :cosine, l2: :euclidean, euclidean: :euclidean}.freeze
      HYBRID_SCORE = "noiseless_hybrid_score"
```

and replace the two "Replaced in Task 7" methods with:

```ruby
      def vector(relation, node)
        definition = vec_definition(node)
        Result.new(
          relation: relation.public_send(definition.name, vector: node.embedding, k: node.k),
          scorer: vector_scorer(definition),
          score_columns: [definition.distance_method, definition.similarity_method],
          cap: node.k,
          relevance: true
        )
      end

      # Both arms run over the filtered relation and fetch k candidates each;
      # the fused list is cut to k.
      def hybrid(relation, node)
        text = TextOptions.new(node.fields, {}, @unsupported)
        fts = hybrid_fts_definition(text.columns)
        vec = vec_definition(node.vector)
        k = node.vector.k
        primary_key = @model.primary_key
        text_ids = if SqliteSearch::Query.build(node.text_query).nil?
          []
        else
          relation.public_send(fts.name, node.text_query, columns: text.columns, **text.query_options)
            .order_by_rank(weights: text.weights).limit(k).pluck(primary_key)
        end
        vector_ids = relation.public_send(vec.name, vector: node.vector.embedding, k: k).pluck(primary_key)
        fused = SqliteSearch::Hybrid.rrf(text_ids, vector_ids, weights: [node.text_weight, node.vector_weight]).first(k)
        raise NoHits if fused.empty?

        Result.new(
          relation: fused_relation(relation, fused),
          scorer: ->(record) { record.public_send(HYBRID_SCORE).to_f },
          score_columns: [HYBRID_SCORE],
          cap: k,
          relevance: true
        )
      end

      def vec_definition(node)
        definition = @model.sqlite_search_vec_for(node.field)
        raise Noiseless::SearchError, "#{@model.name || @model.table_name} has no vec_scope :#{node.field}" unless definition
        unless VECTOR_DISTANCES[node.distance_metric] == definition.distance
          raise Noiseless::SearchError, "vector distance_metric #{node.distance_metric} does not match vec_scope :#{definition.name} (#{definition.distance})"
        end
        definition
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

      # Fused order and score are computed in Ruby, so carry them into SQL as
      # CASE expressions, the way hybrid_scope does.
      def fused_relation(relation, fused)
        ids = fused.map(&:first)
        @model.with_connection do |conn|
          pk_sql = "#{@model.quoted_table_name}.#{conn.quote_column_name(@model.primary_key)}"
          relation.where(@model.primary_key => ids)
            .reorder(Arel.sql(SqliteSearch::Sql.id_case(pk_sql, ids.each_with_index.to_h, conn)))
            .select("#{@model.quoted_table_name}.*, #{SqliteSearch::Sql.id_case(pk_sql, fused.to_h, conn)} AS #{HYBRID_SCORE}")
            .extending(SqliteSearch::ScoredRelation)
        end
      end
```

- [ ] **Step 4: Run to verify pass**

Run: `$R4 bundle exec ruby -Itest -Ilib test/noiseless_adapter/vector_test.rb`
Expected: `0 failures, 0 errors`.

- [ ] **Step 5: Full suites** — `$R4 bundle exec rake test` and `bundle exec rake test` → `0 failures, 0 errors`.

- [ ] **Step 6: Lint** — `bundle exec standardrb` → no offenses.

- [ ] **Step 7: Checkpoint** — do not commit.

```json:metadata
{"files": ["lib/sqlite_search/noiseless_adapter/translator.rb", "test/noiseless_adapter/vector_test.rb"], "verifyCommand": "env PATH=$HOME/.frum/versions/4.0.7/bin:$PATH BUNDLE_GEMFILE=gemfiles/noiseless.gemfile bundle exec rake test", "acceptanceCriteria": ["KNN nearest first, total capped at k, cosine/euclidean scores", "filters and musts pre-filter KNN", "config errors raise in both modes", "hybrid weighted fusion; weights pick winner", "hybrid fts index requirements", "hybrid respects filters"], "requiresUserVerification": false}
```

---

### Task 8: Documentation

**Goal:** README documents the new core options and the noiseless adapter.

**Files:**
- Modify: `README.md`

**Acceptance Criteria:**
- [ ] Full-text "Query" section documents `columns:`, `operator:`, `phrase:`, `minimum_should_match:`; "Ranking" documents `order_by_rank(weights:)`
- [ ] Vector "Query" documents `vector:`; Hybrid documents `fts5_weight:` / `vec_weight:`
- [ ] New "Using with noiseless" section: install/require, config, which scopes serve which queries, strict/lax, support matrix, known differences
- [ ] Every code sample matches the implemented API

**Verify:** `grep -n "Using with noiseless\|vector:\|fts5_weight\|minimum_should_match\|order_by_rank(weights" README.md` → hits in each section

**Steps:**

- [ ] **Step 1: Full-text query options** — in `README.md` under `### Query` (full-text), after the existing code block, add:

````markdown
More options shape the match without giving up sanitizing:

```ruby
Post.search("coffee", columns: [:title])                 # only the title column
Post.search("hot coffee", operator: :or)                 # any term (default :and)
Post.search("flat white", phrase: true)                  # the words as one phrase
Post.search("coffee tea juice", minimum_should_match: 2) # at least 2 of the terms
```

`columns:` must name `against:` columns. `minimum_should_match:` takes an
integer, a negative integer (terms that may be missing), or a percentage
(`"75%"`), following Elasticsearch's rules. It expands into every n-of-m group of
terms, so it accepts at most 6 terms and raises `SqliteSearch::Error` beyond that.
````

- [ ] **Step 2: Ranking weights** — under `### Ranking`, after the threshold paragraph, add:

````markdown
`order_by_rank(weights: { title: 3.0, body: 1.0 })` replaces the `against:`
weights for one query; columns you leave out weigh 0.
````

- [ ] **Step 3: Vector query by vector** — under the vector `### Query`, after the first paragraph, add:

````markdown
If you already have the query's embedding, pass it instead of text and the
embedder is skipped:

```ruby
Post.semantic_search(vector: embedding, k: 20)
```

The vector must have the scope's `dimensions:`; passing both text and `vector:` raises.
````

- [ ] **Step 4: Hybrid weights** — in `## Hybrid search`, after the `fts5_threshold:` example, add:

````markdown
`fts5_weight:` and `vec_weight:` (default 1.0 each) weight each arm's share of
the fused score: `Post.search("coffee", fts5_weight: 2.0)` favors keyword matches.
````

- [ ] **Step 5: noiseless section** — add a new `## Using with noiseless` section before `## Filtering and multi-tenancy`:

````markdown
## Using with noiseless

[noiseless](https://github.com/seuros/noiseless) is a search DSL with
Elasticsearch, OpenSearch, Typesense, and PostgreSQL backends. sqlite_search
ships an opt-in adapter so a noiseless app can run its searches on SQLite.
noiseless needs Ruby 4.0+ and Rails 8.1+; sqlite_search does not depend on it.

```ruby
# Gemfile
gem "noiseless"
gem "sqlite_search"

# config/initializers/sqlite_search_noiseless.rb
require "sqlite_search/noiseless"
```

```yaml
# config/noiseless.yml
development:
  default: primary
  connections:
    primary:
      adapter: sqlite
      unsupported: strict   # or lax
```

The table is the index. A search resolves its ActiveRecord model from the index
name (`index_name "posts"` → `Post`, or `adapter.register_model(Post,
index_name: "posts")`) and runs that model's sqlite_search scopes:

| noiseless | runs as |
|---|---|
| `filter` / `where`, `range`, `sort`, `paginate` | plain ActiveRecord conditions, applied before every search arm |
| `match`, `multi_match`, `combined_fields` | the `fts5_scope` whose `against:` covers the fields, ranked by BM25; `LIKE` when none does |
| `wildcard`, `prefix` | `LIKE` |
| `vector` / `knn` | the `vec_scope` named by the field, with your embedding |
| `hybrid` | the covering `fts5_scope` and the named `vec_scope`, fused with weighted RRF |

Writes (`index_document`, `bulk`, ...) are no-ops: your `fts5_scope` and
`vec_scope` callbacks already keep the indexes current, and `create_index`
does nothing because migrations create them.

Text options follow Elasticsearch where FTS5 can: terms are OR-ed by default,
and `operator`, `type` (`phrase`, `phrase_prefix`, `bool_prefix`; the
`*_fields` types rank alike), field boosts (`"title^3"`),
`minimum_should_match` (up to 6 terms), and `zero_terms_query` are honored.

**Unsupported features.** By default (`unsupported: strict`) a query that uses
something SQLite cannot do raises `Noiseless::SearchError`. With `unsupported:
lax`, a feature whose omission would widen the results (geo filters,
`search_after`, a filter on a field that is not a column) returns no hits, and
one that only decorates the response (aggregations, collapse, `fuzziness`,
pipelines, ...) is skipped and logged. Configuration mistakes, such as a
missing `vec_scope` or a `distance_metric` that does not match the scope,
always raise.

**Known differences from Elasticsearch.** Stemming and tokenizing come from the
FTS5 tokenizer you chose in the migration, the `LIKE` fallback matches
substrings, scores are not on Elasticsearch's scale, and fuzzy matching is not
available.
````

- [ ] **Step 6: Verify samples** — confirm every option name in the new README text matches the code from Tasks 1–7 (`columns:`, `operator:`, `phrase:`, `minimum_should_match:`, `order_by_rank(weights:)`, `vector:`, `fts5_weight:`, `vec_weight:`, `unsupported:`, `register_model`).

Run: `grep -n "Using with noiseless\|vector:\|fts5_weight\|minimum_should_match\|order_by_rank(weights" README.md`
Expected: matches in each of the sections above.

- [ ] **Step 7: Checkpoint** — do not commit.

```json:metadata
{"files": ["README.md"], "verifyCommand": "grep -n \"Using with noiseless\\|vector:\\|fts5_weight\\|minimum_should_match\\|order_by_rank(weights\" README.md", "acceptanceCriteria": ["FTS options and ranking weights documented", "vector: and hybrid weights documented", "noiseless section with config, mapping, strict/lax, differences", "samples match API"], "requiresUserVerification": false}
```
