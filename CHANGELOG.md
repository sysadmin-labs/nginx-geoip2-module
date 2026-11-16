# Changelog

## 3.4.2

First release from this repository, carrying on from upstream's 3.4. It
continues Lee Valentine's module, whose history is intact here; his
repository has had no commit since April 2024.

This replaces 3.4.1 and carries four fixes, two of which are in the stream
module that no job had been building.

### Fixed

- **A write of fourteen bytes past the end of an allocation, on every
  request that read a uint128 field.** The `FORMAT` macro allocated
  `NGX_OFF_T_LEN` for every data type, which is twenty bytes on a 64-bit
  host, and wrote with `ngx_sprintf`, the unbounded one. The uint128 form
  `"0x%016uxL%016uxL"` produces thirty-four characters. `v->len` was then
  set to thirty-four as well, so the response also read past the
  allocation. No sanitizer reported it, because `ngx_palloc` hands out
  slices of a pool block that the allocator sees as one piece; built with
  `-DNGX_DEBUG_PALLOC=1`, which sends every allocation to malloc, the
  worker dies on the first such request. `FORMAT` now takes the size for
  the conversion that writes into it, and uses `ngx_snprintf`, so a wrong
  size cannot reach past the allocation either. Both the HTTP and the
  stream module.
- **The byte-array form of the same conversion read no arguments at all.**
  Where `MMDB_UINT128_IS_BYTE_ARRAY` is set, the format was sixteen
  `%02x`. In nginx's printf `x` only sets the hex flag and leaves the type
  to the next character, so each `%02x` was followed by `%`, which prints
  a per-cent sign and consumes nothing: the output was a row of per-cent
  signs and the sixteen arguments were never read. It uses
  `ngx_hex_dump` now.
- **`$var;` and `$var metadata;` read `cf->args` past its end.** The check
  was `nelts > 0` before looking at `value[1]`, and the metadata path took
  `value[2]` with no check at all. `cf->args` comes from
  `ngx_array_create` and is not zeroed, so what was read was whatever the
  previous configuration line had left in that slot: `nginx -t` died
  during the configuration pass, or the server started and then compared a
  wild pointer on every request. A variable with no lookup path is legal
  and now simply answers empty; `metadata` without a field name is
  refused with a message naming the three fields it takes.
- **`auto_reload` did not drop the lookup cache.** After `MMDB_close` and
  the swap to the new file, `database->address` still held the last
  client's address and `database->result` an entry offset into the mapping
  that had just been closed. The next request from that address skipped
  the lookup and read the new file at the old file's offset. Both are
  cleared on reload now.

### Added

- Continuous integration against nginx 1.28, 1.30 and 1.31, statically and
  dynamically, with sanitizers, valgrind, CodeQL, a reload gate and a
  FreeBSD run.
- `t/00-directives.t`, which asks real questions of MaxMind's own test
  database rather than only checking that the configuration parses.
- `ci/testdb.sh`, which fetches that test database pinned by commit and
  digest, and MaxMind's decoder database next to it. It is MIT-licensed
  test data and is not kept in this repository. The decoder database
  carries one field of every mmdb type, and the city database carries none
  of the wider numeric ones, so without it the uint128 conversion above
  could not be reached by a test at all.
- `ci/stream.sh`, the gate for `src/ngx_stream_geoip2_module.c`.
  Test::Nginx speaks HTTP, so the suite can only ever exercise the HTTP
  half; this one asks a lookup through a stream connection, checks the
  default for a miss, and checks the two short blocks above.
- A check in `ci/build.sh` that both module sources were compiled. The
  warning gate can only report files the build saw, so a source left out
  of the build makes it quieter rather than louder, which is how the
  stream half came to be unchecked.

### Changed

- Sources moved to `src/`.
- `ci/build.sh` passes `--with-stream`, so the stream module is built.
  Without it `config` skipped those 694 lines entirely: they were outside
  the warning gate, outside CodeQL, outside the sanitizers and outside
  valgrind, while the README told the reader to load the object. Two of
  the fixes above are in that file.
- The sanitizer workflow builds with `-DNGX_DEBUG_PALLOC=1` and collects
  the reports through `log_path`. nginx redirects its own stderr onto the
  error log file as soon as `error_log` names one, and Test::Nginx always
  names one, so reports on stderr were lost: ASan was noticed only
  through the worker dying, and UBSan not at all.
- `config` uses the `auto/module` form only; the pre-1.9.11 branch it
  carried alongside could build neither a loadable module nor the stream
  one. The stream module's own version check went with it, since 1.11.1 is
  far below the floor here.
