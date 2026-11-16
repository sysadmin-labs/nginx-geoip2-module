# nginx-geoip2-module

[![Build][build-test-badge]][build-test-link]
[![Lint][lint-badge]][lint-link]
[![CodeQL][codeql-badge]][codeql-link]
[![A/UBSan][sanitizers-badge]][sanitizers-link]
[![Valgrind][valgrind-badge]][valgrind-link]
[![Reload][reload-badge]][reload-link]
[![FreeBSD][freebsd-badge]][freebsd-link]

[build-test-badge]: https://github.com/sysadmin-labs/nginx-geoip2-module/actions/workflows/build-test.yml/badge.svg
[build-test-link]: https://github.com/sysadmin-labs/nginx-geoip2-module/actions/workflows/build-test.yml
[lint-badge]: https://github.com/sysadmin-labs/nginx-geoip2-module/actions/workflows/lint.yml/badge.svg
[lint-link]: https://github.com/sysadmin-labs/nginx-geoip2-module/actions/workflows/lint.yml
[codeql-badge]: https://github.com/sysadmin-labs/nginx-geoip2-module/actions/workflows/codeql.yml/badge.svg
[codeql-link]: https://github.com/sysadmin-labs/nginx-geoip2-module/actions/workflows/codeql.yml
[sanitizers-badge]: https://github.com/sysadmin-labs/nginx-geoip2-module/actions/workflows/sanitizers.yml/badge.svg
[sanitizers-link]: https://github.com/sysadmin-labs/nginx-geoip2-module/actions/workflows/sanitizers.yml
[valgrind-badge]: https://github.com/sysadmin-labs/nginx-geoip2-module/actions/workflows/valgrind.yml/badge.svg
[valgrind-link]: https://github.com/sysadmin-labs/nginx-geoip2-module/actions/workflows/valgrind.yml
[reload-badge]: https://github.com/sysadmin-labs/nginx-geoip2-module/actions/workflows/reload.yml/badge.svg
[reload-link]: https://github.com/sysadmin-labs/nginx-geoip2-module/actions/workflows/reload.yml
[freebsd-badge]: https://github.com/sysadmin-labs/nginx-geoip2-module/actions/workflows/freebsd.yml/badge.svg
[freebsd-link]: https://github.com/sysadmin-labs/nginx-geoip2-module/actions/workflows/freebsd.yml

Read MaxMind's GeoIP2 and GeoLite2 databases from nginx and put what they
say into variables, for HTTP requests and for stream connections.

nginx's own `geoip` module reads the legacy format MaxMind stopped
publishing in 2019. This reads the current one.

## Requirements

nginx 1.28 or newer, and libmaxminddb. On FreeBSD that is
`net/libmaxminddb`, on Debian and Ubuntu `libmaxminddb-dev`.

A database to read. The free GeoLite2 files need a MaxMind account; the
licensed GeoIP2 ones do not come from here either. Neither is in this
repository, and the test suite uses MaxMind's small test database instead,
fetched by `ci/testdb.sh`.

## Building

```sh
./configure --add-module=/path/to/nginx-geoip2-module
```

Both the HTTP and the stream module are built. As loadable modules,
`--add-dynamic-module=` and then

```nginx
load_module modules/ngx_http_geoip2_module.so;
load_module modules/ngx_stream_geoip2_module.so;
```

## Quick start

```nginx
http {
    geoip2 /usr/local/share/GeoIP/GeoLite2-Country.mmdb {
        auto_reload 60m;
        $geoip2_country_code default=XX country iso_code;
        $geoip2_country_name              country names en;
    }

    geoip2 /usr/local/share/GeoIP/GeoLite2-City.mmdb {
        $geoip2_city      city names en;
        $geoip2_latitude  location latitude;
        $geoip2_longitude location longitude;
    }

    server {
        location / {
            return 200 "$geoip2_country_code $geoip2_city\n";
        }
    }
}
```

The path after a variable name is the path through the database's own
structure, so `country names en` is the English country name and
`subdivisions 0 iso_code` the first subdivision's code. What a database
holds is in MaxMind's documentation for that database.

## Directives

### geoip2

|Syntax |`geoip2 path { ... }`|
|-------|---|
|Default|none|
|Context|http, stream|

Open a database and declare the variables read from it. One block per
database; several blocks are fine.

Inside the block:

```
auto_reload <time>;
$variable [default=<value>] [source=$other] <path...>;
```

`auto_reload` re-reads the file when it changes on disk, which is how a
monthly database update takes effect without a reload. `default=` is used
when the lookup finds nothing. `source=` names the variable holding the
address to look up; without it `$remote_addr` is used.

`metadata` in place of a lookup path reads the database's own metadata
rather than an address:

```nginx
geoip2 /usr/local/share/GeoIP/GeoLite2-City.mmdb {
    auto_reload 60m;
    $geoip2_build  metadata build_epoch;
    $geoip2_check  metadata last_check;
    $geoip2_change metadata last_change;
}
```

which is how a monitoring endpoint can report how old the database is.

### geoip2\_proxy

|Syntax |`geoip2_proxy address \| CIDR`|
|-------|---|
|Default|none|
|Context|http|

Trust `X-Forwarded-For` from these addresses and look up what it says
instead of the peer. May be given more than once.

### geoip2\_proxy\_recursive

|Syntax |`geoip2_proxy_recursive on \| off`|
|-------|---|
|Default|`off`|
|Context|http|

Walk `X-Forwarded-For` from the right until an address outside
`geoip2_proxy` is found, rather than taking the last entry.

## Testing

```sh
ci/testdb.sh t/data/GeoIP2-City-Test.mmdb
ci/build.sh 1.30.6 /tmp/nginx-test
TEST_NGINX_BINARY=/tmp/nginx-test/sbin/nginx prove -r t/
ci/stream.sh /tmp/nginx-test/sbin/nginx t/data/MaxMind-DB-test-decoder.mmdb
ci/reload.sh /tmp/nginx-test/sbin/nginx
```

`ci/testdb.sh` fetches MaxMind's MIT-licensed test databases, pinned by
commit and digest: the city database, and the decoder database that
carries one field of every mmdb data type. The suite asks for an address
that is in the city database and checks the country, a nested city
lookup, a miss with and without a default, and that a database which is
not there is refused at startup. Against the decoder database it checks
every numeric conversion, including the uint128 one that writes
thirty-four characters.

`ci/stream.sh` is the stream module's gate. Test::Nginx speaks HTTP, so
the suite reaches only the HTTP half; this one puts a lookup through a
stream connection and checks the answer. Build with `--with-stream`, which
`ci/build.sh` passes.

## License

BSD 2-Clause. See `LICENSE`.
