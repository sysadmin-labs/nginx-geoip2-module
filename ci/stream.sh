#!/bin/sh
#
# The stream half of this module, which the Perl suite cannot reach.
#
# Test::Nginx speaks HTTP, so t/ can only ever exercise
# src/ngx_http_geoip2_module.c.  src/ngx_stream_geoip2_module.c is built
# from the same config file under "if [ $STREAM != NO ]", and for a while
# nothing here passed --with-stream: those lines were compiled by no job,
# so the warning gate, CodeQL, the sanitizers and valgrind all ran green
# over a module half of which they had never seen.  This script is that
# half's gate.
#
#     ci/stream.sh <nginx binary> [path to the test mmdb]
#
# Set STREAM_LOAD_MODULE to the objects to load, in the order they have to
# be loaded in, separated by spaces; STREAM_PORT moves the listener.
#
# THE ORDER MATTERS.  A loadable stream module resolves
# ngx_stream_core_module out of ngx_stream_module.so, so that object has to
# be loaded first: nginx reports "undefined symbol: ngx_stream_core_module"
# otherwise and refuses to start.  A packager offering this module as a
# loadable object has the same problem, and alphabetical order is the wrong
# one -- ngx_stream_geoip2_module sorts before ngx_stream_module.
#
# WHAT IS ASSERTED, and why each one is shaped the way it is:
#
#   A geoip2 block inside stream{} is accepted.  This is the oracle for
#   "the stream module is in this binary at all": without it nginx rejects
#   the block as an unknown directive, which is exactly what a build
#   without --with-stream produces.  It cannot pass by accident.
#
#   A lookup through a stream connection answers with the country from the
#   database.  The address cannot come from the peer -- every connection
#   here arrives from 127.0.0.1, which is in no database -- so it is put
#   into a variable with map, the same way source= is fed in the HTTP
#   suite.  This is what proves the module runs, rather than merely parses.
#
#   A miss gives the configured default.  Separate from the hit, because a
#   module that answers nothing at all would otherwise pass the hit test
#   for an address it also does not find.
#
#   Two short blocks are read as what they are, rather than past their
#   end.  "$var;" and "$var metadata;" used to read cf->args past nelts,
#   which is not zeroed: nginx either died during the configuration pass
#   or started and then dereferenced whatever the previous line had left
#   in that slot.  The two correct outcomes differ: a variable with no
#   lookup path is a usable thing that simply answers empty, so it is
#   accepted, while "metadata" without a field name has nothing to look up
#   and is refused with a message.  Both are asserted here.

set -eu

NGINX=${1:?path to the nginx binary missing}
SRC=$(cd "$(dirname "$0")/.." && pwd)
DB=${2:-$SRC/t/data/GeoIP2-City-Test.mmdb}
# Made absolute here: nginx reads the configuration with its own prefix as
# the working directory, so a relative path given on the command line
# would be looked for somewhere else entirely, and the failure reads as
# "the module is missing" rather than "the file is not there".
case $DB in
/*) ;;
*)  DB=$(cd "$(dirname "$DB")" && pwd)/$(basename "$DB") ;;
esac
WORK=${CI_WORK:-$SRC/ci-work}/stream
PORT=${STREAM_PORT:-18300}

# In the database as GB, London, Boxford; the HTTP suite asks the same
# address, so a disagreement between the two halves is visible.
HIT=2.125.160.216
MISS=203.0.113.1

command -v nc > /dev/null || { echo "nc(1) is needed" >&2; exit 2; }
[ -r "$DB" ] || { echo "ci/stream.sh: cannot read $DB" >&2; exit 2; }

rm -rf "$WORK"
mkdir -p "$WORK/conf" "$WORK/logs"

ngx_user=
if [ "$(id -u)" = 0 ]; then
	ngx_user="user root $(id -gn);"
fi

ngx_load=
for so in ${STREAM_LOAD_MODULE:-}; do
	[ -f "$so" ] || { echo "ci/stream.sh: no such module: $so" >&2; exit 2; }
	ngx_load="$ngx_load
load_module $so;"
done

fail=0
note() {
	echo "  $1" >&2
	fail=1
}

# $probe carries the address to look up, because $remote_addr is always
# 127.0.0.1 here.  Two ports, so that one configuration covers the hit and
# the miss without a reload in between.
write_conf() {
	cat > "$WORK/conf/nginx.conf" <<EOF
$ngx_load
$ngx_user
worker_processes 1;
error_log $WORK/logs/error.log info;
pid $WORK/logs/nginx.pid;
events { worker_connections 64; }
stream {
    geoip2 $DB {
        \$country  source=\$probe country iso_code;
        \$fallback source=\$probe default=ZZ country iso_code;
    }

    map \$server_port \$probe {
        $PORT        $HIT;
        default      $MISS;
    }

    server {
        listen 127.0.0.1:$PORT;
        return "\$country\n";
    }

    server {
        listen 127.0.0.1:$((PORT + 1));
        return "\$fallback\n";
    }
}
EOF
}

probe() {
	nc 127.0.0.1 "$1" < /dev/null 2> /dev/null | tr -d '\r\n'
}

echo "--- a geoip2 block inside stream{} is accepted ---"
write_conf
if "$NGINX" -p "$WORK" -c conf/nginx.conf -t 2> "$WORK/t.log"; then
	echo "  yes, so this binary carries the stream module"
elif grep -q 'unknown directive' "$WORK/t.log"; then
	cat "$WORK/t.log" >&2
	note "the stream module is not in this binary: was it built without --with-stream?"
	exit 1
else
	# Refused for some other reason: an unreadable database, a port
	# already taken.  Saying "the module is missing" here would send
	# the next reader after the wrong thing.
	cat "$WORK/t.log" >&2
	note "the configuration was refused, see above"
	exit 1
fi

"$NGINX" -p "$WORK" -c conf/nginx.conf
sleep 1

stop() {
	[ -s "$WORK/logs/nginx.pid" ] && kill "$(cat "$WORK/logs/nginx.pid")" 2> /dev/null
	return 0
}
trap stop EXIT

echo "--- a lookup through a stream connection answers ---"
got=$(probe "$PORT" || true)
if [ "$got" = GB ]; then
	echo "  $HIT -> $got"
elif [ -z "$got" ]; then
	# Empty rather than wrong: the module answered, the address was not
	# found.  Almost always the wrong database -- the decoder database
	# has one record and no country in it -- and saying "expected GB"
	# for that sends the reader after the module instead of the file.
	note "no country for $HIT in $DB; is this the city database?"
else
	note "expected \"GB\" for $HIT, got \"$got\""
fi

echo "--- a miss gives the configured default ---"
got=$(probe "$((PORT + 1))" || true)
if [ "$got" = ZZ ]; then
	echo "  $MISS -> $got"
else
	note "expected \"ZZ\" for $MISS, got \"$got\""
fi

stop
trap - EXIT

# The two forms that used to read past cf->args->nelts.  Asserted as a
# refusal with a message, not merely as a non-zero exit: a crash during the
# configuration pass also exits non-zero, and that is the bug, not the fix.
echo "--- a variable with no lookup path is accepted and answers empty ---"
cat > "$WORK/conf/lonely.conf" <<EOF
$ngx_load
$ngx_user
worker_processes 1;
error_log $WORK/logs/lonely.log info;
pid $WORK/logs/nginx.pid;
events { worker_connections 64; }
stream {
    geoip2 $DB {
        \$lonely;
    }
    server { listen 127.0.0.1:$PORT; return "[\$lonely]\n"; }
}
EOF
if "$NGINX" -p "$WORK" -c conf/lonely.conf -t > "$WORK/lonely.t" 2>&1; then
	"$NGINX" -p "$WORK" -c conf/lonely.conf
	sleep 1
	got=$(probe "$PORT" || true)
	if [ "$got" = "[]" ]; then
		echo "  answered \"$got\""
	else
		note "expected \"[]\", got \"$got\""
	fi
	[ -s "$WORK/logs/nginx.pid" ] && kill "$(cat "$WORK/logs/nginx.pid")" 2> /dev/null
	sleep 1
else
	cat "$WORK/lonely.t" >&2
	note "the configuration was refused; one word on the line is legal"
fi

echo "--- metadata without a field name is refused ---"
cat > "$WORK/conf/bad2.conf" <<EOF
$ngx_load
$ngx_user
worker_processes 1;
error_log $WORK/logs/bad2.log info;
pid $WORK/logs/nginx.pid;
events { worker_connections 64; }
stream {
    geoip2 $DB {
        \$meta metadata;
    }
    server { listen 127.0.0.1:$PORT; return "x\n"; }
}
EOF
out=$("$NGINX" -p "$WORK" -c conf/bad2.conf -t 2>&1) && rc=0 || rc=$?
if [ "$rc" != 0 ] && echo "$out" | grep -q 'needs the name of a field'; then
	echo "  refused: $(echo "$out" | grep -o 'needs the name of a field.*' | head -1)"
else
	echo "$out" >&2
	note "expected the field-name refusal, exit was $rc"
fi

echo "--- the error log stayed quiet ---"
if grep -qE '\[alert\]|\[crit\]|SIGSEGV|SIGABRT|SIGBUS' "$WORK/logs/error.log" 2> /dev/null; then
	grep -nE '\[alert\]|\[crit\]|SIGSEGV|SIGABRT|SIGBUS' "$WORK/logs/error.log" | head -5 >&2
	note "see the lines above"
else
	echo "  no alert, no crit, no signal"
fi

[ "$fail" -eq 0 ]
