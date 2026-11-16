# The directives parse and the lookups answer out of MaxMind's test
# database.
#
# t/data/GeoIP2-City-Test.mmdb is fetched by ci/testdb.sh before the suite
# runs; it is MaxMind's own MIT-licensed test data, not a licensed
# production database.  2.125.160.216 is in it as GB, London, Boxford.

use Test::Nginx::Socket 'no_plan';

my $db = $ENV{TEST_MMDB} || "$ENV{PWD}/t/data/GeoIP2-City-Test.mmdb";

# The decoder database carries one field of every mmdb data type.  The city
# database above has none of the wider numeric ones, so the conversions for
# uint64, uint128 and the floating point types are only reachable here.
# Every address in it answers out of the same record.
my $decoder = $ENV{TEST_MMDB_DECODER}
    || "$ENV{PWD}/t/data/MaxMind-DB-test-decoder.mmdb";
our $DecoderConfig = qq{
    geoip2 $decoder {
        \$d_uint128     source=\$http_x_probe_ip uint128;
        \$d_uint64      source=\$http_x_probe_ip uint64;
        \$d_uint32      source=\$http_x_probe_ip uint32;
        \$d_int32       source=\$http_x_probe_ip int32;
        \$d_float       source=\$http_x_probe_ip float;
        \$d_double      source=\$http_x_probe_ip double;
        \$d_boolean     source=\$http_x_probe_ip boolean;
        \$d_utf8        source=\$http_x_probe_ip utf8_string;
    }
};

# "metadata" takes the name of a field after it.  Without one the module
# used to read cf->args past nelts, which is not zeroed: nginx either died
# during the configuration pass or started and then dereferenced whatever
# had been left there by the previous line.
our $LonelyVar = qq{
    geoip2 $decoder {
        \$lonely;
    }
};
our $MetaNoField = qq{
    geoip2 $decoder {
        \$meta metadata;
    }
};
our $MetaWithField = qq{
    geoip2 $decoder {
        \$meta_epoch metadata build_epoch;
    }
};
our $HttpConfig = qq{
    geoip2 $db {
        \$probe_country  source=\$http_x_probe_ip country iso_code;
        \$probe_city     source=\$http_x_probe_ip city names en;
        \$probe_default  source=\$http_x_probe_ip default=ZZ country iso_code;
    }
};

# geoip2_proxy and geoip2_proxy_recursive are http-level directives, not
# server-level, so they belong here and not beside a location.
our $HttpConfigProxy = $HttpConfig . q{
    geoip2_proxy           127.0.0.0/8;
    geoip2_proxy_recursive on;
};

repeat_each(1);
run_tests();

__DATA__

=== TEST 1: a country out of the database
--- http_config eval: $::HttpConfig
--- config
    location /t { return 200 "$probe_country\n"; }
--- more_headers
X-Probe-IP: 2.125.160.216
--- request
GET /t
--- response_body
GB



=== TEST 2: a city name, which is a nested lookup
--- http_config eval: $::HttpConfig
--- config
    location /t { return 200 "$probe_city\n"; }
--- more_headers
X-Probe-IP: 2.125.160.216
--- request
GET /t
--- response_body
Boxford



=== TEST 3: an address that is not in the database gives the default
--- http_config eval: $::HttpConfig
--- config
    location /t { return 200 "$probe_default\n"; }
--- more_headers
X-Probe-IP: 203.0.113.1
--- request
GET /t
--- response_body
ZZ



=== TEST 4: without a default, a miss is empty
--- http_config eval: $::HttpConfig
--- config
    location /t { return 200 "[$probe_country]\n"; }
--- more_headers
X-Probe-IP: 203.0.113.1
--- request
GET /t
--- response_body
[]



=== TEST 5: geoip2_proxy and its recursive form parse
--- http_config eval: $::HttpConfigProxy
--- config
    location /t { return 200 "ok\n"; }
--- request
GET /t
--- response_body
ok



=== TEST 6: every numeric type converts, and uint128 is the long one
--- http_config eval: $::DecoderConfig
--- config
    location /t {
        return 200 "$d_uint128|$d_uint64|$d_uint32|$d_int32|$d_boolean\n";
    }
--- more_headers
X-Probe-IP: 1.1.1.1
--- request
GET /t
--- response_body
0x01000000000000000000000000000000|1152921504606846976|268435456|-268435456|1



=== TEST 7: uint128 writes thirty-four characters, and nothing more
--- http_config eval: $::DecoderConfig
--- config
    # The length matters on its own, not just the text: the conversion
    # allocated NGX_OFF_T_LEN, twenty bytes on a 64-bit host, and wrote
    # thirty-four into it with the unbounded ngx_sprintf.  Asserting the
    # length here means a conversion that silently starts truncating is
    # a failure too, not a quiet pass.
    location /t { return 200 "$d_uint128 len\n"; }
--- more_headers
X-Probe-IP: 1.1.1.1
--- request
GET /t
--- response_body_like: ^0x[0-9a-f]{32} len$



=== TEST 8: the floating point types keep five fractional digits
--- http_config eval: $::DecoderConfig
--- config
    location /t { return 200 "$d_float|$d_double\n"; }
--- more_headers
X-Probe-IP: 1.1.1.1
--- request
GET /t
--- response_body
1.10000|42.12346



=== TEST 9: a string out of the decoder database
--- http_config eval: $::DecoderConfig
--- config
    location /t { return 200 "$d_utf8\n"; }
--- more_headers
X-Probe-IP: 1.1.1.1
--- request
GET /t
--- response_body
unicode! ☯ - ♫



=== TEST 10: a variable with no lookup path is read as such, not past
--- http_config eval: $::LonelyVar
--- config
    # One word on the line, so there is no value[1] to read.  cf->args
    # comes from ngx_array_create and is not zeroed, so the old check of
    # "nelts > 0" read whatever the previous configuration line had left
    # in that slot: nginx died during the configuration pass, or started
    # and then compared a wild pointer on every request.  Accepting the
    # line and answering empty is the correct outcome, and asserting the
    # answer is what makes this a gate rather than a parse check.
    location /t { return 200 "[$lonely]\n"; }
--- more_headers
X-Probe-IP: 1.1.1.1
--- request
GET /t
--- response_body
[]



=== TEST 11: metadata without a field name is refused
--- http_config eval: $::MetaNoField
--- config
    location /t { return 200 "ok\n"; }
--- must_die
--- error_log
needs the name of a field



=== TEST 12: metadata with a field name answers
--- http_config eval: $::MetaWithField
--- config
    location /t { return 200 "$meta_epoch\n"; }
--- request
GET /t
--- response_body_like: ^\d+$



=== TEST 13: a database that is not there is refused at startup
--- http_config
    geoip2 /nonexistent/nowhere.mmdb {
        $nope country iso_code;
    }
--- config
    location /t { return 200 "ok\n"; }
--- must_die
