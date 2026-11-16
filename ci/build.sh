#!/bin/sh
#
# Build an nginx that carries this module.  The continuous integration
# workflow runs this, and so can you:
#
#     ci/build.sh 1.31.6 /tmp/nginx-test
#     TEST_NGINX_BINARY=/tmp/nginx-test/sbin/nginx prove -r t/
#
# usage: ci/build.sh <nginx version> <install prefix> [mode]
#
#     static    the module built into the binary (the default)
#     dynamic   the module built as a loadable object
#
# nginx lands in $CI_WORK, ./ci-work by default, and is reused on a
# second run.  A warning from this module's own source fails the build.

set -eu

NGINX=${1:?nginx version missing}
PREFIX=${2:?install prefix missing}
MODE=${3:-static}

SRC=$(cd "$(dirname "$0")/.." && pwd)
WORK=${CI_WORK:-$SRC/ci-work}
JOBS=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)

# Every version, digest and commit comes from one file, so a run here pins
# exactly what a continuous integration run pins.  Deliberately not
# overridable from the environment: a version and the digest that proves it
# have to move together, and an override would separate them.
PINS=$SRC/.github/versions.env
[ -r "$PINS" ] || {
	echo "ci/build.sh: cannot read $PINS" >&2
	exit 1
}
# shellcheck source=../.github/versions.env
. "$PINS"

mkdir -p "$WORK"

tarball=$WORK/nginx-$NGINX.tar.gz
url=https://nginx.org/download/nginx-$NGINX.tar.gz

# The digest is looked up by version, so building another release means
# writing its pin down first.  A missing pin is refused rather than waved
# through: a check that skips itself when it has nothing to compare against
# is not a check, it only looks like one.
key=NGINX_$(echo "$NGINX" | tr . _)_SHA256
eval "want=\${$key:-}"
if [ -z "$want" ]; then
	echo "ci/build.sh: no sha256 for nginx $NGINX in $PINS" >&2
	echo "ci/build.sh: harvest one with" >&2
	echo "    ci/fetch-verify.sh $url - $tarball" >&2
	exit 1
fi

"$SRC/ci/fetch-verify.sh" "$url" "$want" "$tarball"

rm -rf "$WORK/nginx-$NGINX"
tar xzf "$tarball" -C "$WORK"

case $MODE in
static)
	how=--add-module
	;;
dynamic)
	how=--add-dynamic-module
	;;
*)
	echo "ci/build.sh: unknown mode \"$MODE\"" >&2
	exit 2
	;;
esac

cd "$WORK/nginx-$NGINX"

# Not what the module needs, what the test suite needs: with ssl there is a
# proxy module to put an upstream behind, and stub_status makes a request
# left behind in the worker countable.

# --with-stream is what the module's second half needs: config builds
# src/ngx_stream_geoip2_module.c only when $STREAM is set, so without this
# those 694 lines are never compiled, and neither the warning gate, CodeQL,
# the sanitizers nor valgrind ever see them.  A loadable build asks for the
# subsystem as a loadable object too, which is what a binary from the
# FreeBSD ports looks like and what sets $STREAM to DYNAMIC rather than YES.
if [ "$MODE" = dynamic ]; then
	stream=--with-stream=dynamic
else
	stream=--with-stream
fi

# the sanitizer workflow builds through this script as well, so that
# there is one build path and not two that drift apart
set --
if [ -n "${CI_CC_OPT:-}" ]; then
	set -- "$@" --with-cc-opt="$CI_CC_OPT"
fi
if [ -n "${CI_LD_OPT:-}" ]; then
	set -- "$@" --with-ld-opt="$CI_LD_OPT"
fi

echo "--- configure ($MODE) ---"
./configure --prefix="$PREFIX" --with-debug "$stream" \
	--with-http_ssl_module --with-http_stub_status_module \
	"$how=$SRC" "$@" > "$WORK/configure-$NGINX.log" 2>&1 ||
	{ tail -30 "$WORK/configure-$NGINX.log"; exit 1; }

echo "--- make -j$JOBS ---"
make -j"$JOBS" > "$WORK/make-$NGINX.log" 2>&1 ||
	{ tail -40 "$WORK/make-$NGINX.log"; exit 1; }

# Anchored on this repository's own source directory, so every file the
# module brings is covered and nginx's own are not.  Matching on one
# file name instead would leave the rest of a multi-file module
# unchecked.
if grep -E "^$SRC/src/.*warning" "$WORK/make-$NGINX.log"; then
	echo "ci/build.sh: the compiler warned about this module, see above" >&2
	exit 1
fi

# The warning gate above can only report files the build actually saw, so
# a module source left out of the build makes it quieter, not louder.
# That is how src/ngx_stream_geoip2_module.c came to be unchecked.  Assert
# instead that every source this module declares was compiled.
for part in ngx_http_geoip2_module ngx_stream_geoip2_module; do
	if ! grep -q "$part\.o" "$WORK/make-$NGINX.log"; then
		echo "ci/build.sh: $part was not compiled" >&2
		grep -c . "$WORK/make-$NGINX.log" > /dev/null
		exit 1
	fi
done

make install > /dev/null
"$PREFIX/sbin/nginx" -v
