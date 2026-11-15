# Changelog

## 3.4.1

First release from this repository, carrying on from upstream's 3.4. It
continues Lee Valentine's module, whose history is intact here; his
repository has had no commit since April 2024.

### Added

- Continuous integration against nginx 1.28, 1.30 and 1.31, statically and
  dynamically, with sanitizers, valgrind, CodeQL, a reload gate and a
  FreeBSD run.
- `t/00-directives.t`, which asks real questions of MaxMind's own test
  database rather than only checking that the configuration parses.
- `ci/testdb.sh`, which fetches that test database pinned by commit and
  digest. It is MIT-licensed test data and is not kept in this repository.

### Changed

- Sources moved to `src/`.
- `config` uses the `auto/module` form only; the pre-1.9.11 branch it
  carried alongside could build neither a loadable module nor the stream
  one. The stream module's own version check went with it, since 1.11.1 is
  far below the floor here.
