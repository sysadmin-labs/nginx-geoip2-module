# The directives parse and the lookups answer out of MaxMind's test
# database.
#
# t/data/GeoIP2-City-Test.mmdb is fetched by ci/testdb.sh before the suite
# runs; it is MaxMind's own MIT-licensed test data, not a licensed
# production database.  2.125.160.216 is in it as GB, London, Boxford.

use Test::Nginx::Socket 'no_plan';

my $db = $ENV{TEST_MMDB} || "$ENV{PWD}/t/data/GeoIP2-City-Test.mmdb";
our $HttpConfig = qq{
    geoip2 $db {
        \$probe_country  source=\$http_x_probe_ip country iso_code;
        \$probe_city     source=\$http_x_probe_ip city names en;
        \$probe_default  source=\$http_x_probe_ip default=ZZ country iso_code;
    }
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
--- http_config eval: $::HttpConfig
--- config
    geoip2_proxy           127.0.0.0/8;
    geoip2_proxy_recursive on;
    location /t { return 200 "ok\n"; }
--- request
GET /t
--- response_body
ok



=== TEST 6: a database that is not there is refused at startup
--- http_config
    geoip2 /nonexistent/nowhere.mmdb {
        $nope country iso_code;
    }
--- config
    location /t { return 200 "ok\n"; }
--- must_die
