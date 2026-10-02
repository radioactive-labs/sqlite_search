# Security Policy

sqlite_search turns user input into SQLite queries, so a flaw here can expose
data in every app that uses it. We appreciate responsible disclosure.

## Supported versions

sqlite_search is pre-1.0. Security fixes are released against the **latest
published minor version** only. If you run an older release, please upgrade and
confirm the issue still reproduces before reporting it.

| Version | Supported |
| ------- | --------- |
| Latest `0.x` release | ✅ |
| Older releases | ❌ |

## Reporting a vulnerability

**Please do not report security vulnerabilities through public GitHub issues,
discussions, or pull requests.**

Use one of these private channels instead:

- **Preferred:** [open a private vulnerability report](https://github.com/radioactive-labs/sqlite_search/security/advisories/new)
  (the **Security** tab, then **Report a vulnerability**). Only the maintainers
  can see it.
- **Email:** [sfroelich01@gmail.com](mailto:sfroelich01@gmail.com) with the
  subject line `[SECURITY] sqlite_search`.

To help us triage quickly, include as much of this as you can:

- The sqlite_search, Rails, and SQLite versions affected.
- A description of the vulnerability and its impact.
- Steps to reproduce, or a proof of concept.
- Any known workarounds.

## What to expect

- **Acknowledgement:** within **3 business days**.
- **Assessment:** we will confirm whether the report is accepted and give an
  expected timeline for a fix.
- **Disclosure:** we follow coordinated disclosure, agree a disclosure date with
  you once a fix is available, and credit you in the advisory unless you prefer
  to stay anonymous.

Please give us a reasonable opportunity to release a fix before any public
disclosure.

## Guarantees you can hold us to

These are the security properties sqlite_search is designed to provide. A way
around any of them is in scope, and we especially want to hear about it.

- **Search input cannot inject FTS5 syntax.** A query passed as the positional
  argument goes through `SqliteSearch::Query`, which keeps only quoted phrases
  and Unicode letter, digit, and underscore terms, and drops FTS5 operators and
  punctuation. Passing `params[:q]` straight through is intended to be safe.
- **Values never reach SQL unquoted.** Query text, ids, distances, and scores
  are bound or quoted through the database connection, and table and column
  names are quoted as identifiers.
- **Chained conditions scope every arm.** Conditions chained before a search
  (`Post.where(tenant_id: 5).search(...)`) filter the keyword search, the vector
  search, and both arms of a hybrid search before results are ranked, so a
  search does not return rows the chained scope excludes.
- **A reranker cannot add results.** Records a reranker returns that were not in
  the fused candidate set are discarded.

## Out of scope

- **`raw:` queries.** `raw:` deliberately bypasses the sanitizer and passes FTS5
  syntax through unchanged. It is for trusted, internally built expressions, and
  passing user input to it is a bug in the calling app.
- **Migration helper arguments.** `create_fts5_index` and `create_vec_index`
  options (table names, tokenizer, dimensions) are developer input and are not
  sanitized.
- **Your embedder and reranker.** The blocks you register are your app's code,
  as are the services they call.
- **Dependencies.** Report issues in SQLite, sqlite-vec, `neighbor`, or Rails to
  their maintainers, though if sqlite_search triggers one through how it uses
  the dependency, we would like to hear about it.
