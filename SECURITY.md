# Security Policy

## Supported versions

The latest released `0.x` line receives security fixes. Until the gem reaches
1.0, only the most recent minor version is supported.

## Reporting a vulnerability

Please report suspected vulnerabilities privately rather than opening a public
issue. Use GitHub's [private security advisory](https://github.com/radioactive-labs/sqlite_search/security/advisories/new)
for the repository, or email sfroelich01@gmail.com. We aim to acknowledge a
report within a few business days.

When search input is involved, note that `SqliteSearch::Query` sanitizes the
positional query argument into a safe FTS5 `MATCH` expression, so untrusted
input is expected to be safe there. The `raw:` option deliberately bypasses that
sanitizer and must only be used with trusted, internally built expressions.
