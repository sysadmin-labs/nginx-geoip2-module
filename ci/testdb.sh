#!/bin/sh
#
# Fetch MaxMind's test database, the one the module is asked questions
# against.  It is MIT licensed test data from the MaxMind-DB repository,
# not a licensed production database, and it is not kept in this
# repository: a binary blob in git that nobody can read or diff is worse
# than a pinned download.
#
#     ci/testdb.sh /tmp/GeoIP2-City-Test.mmdb
#
# The decoder database, which carries a field of every mmdb data type, is
# fetched next to it under the name MaxMind-DB-test-decoder.mmdb.  The city
# database has none of the wider numeric types, so the conversions for
# uint64, uint128 and the floating point types are only reachable through
# that one.

set -eu

OUT=${1:?output path missing}

SRC=$(cd "$(dirname "$0")/.." && pwd)
PINS=$SRC/.github/versions.env
[ -r "$PINS" ] || { echo "ci/testdb.sh: cannot read $PINS" >&2; exit 1; }
# shellcheck source=../.github/versions.env
. "$PINS"

: "${MMDB_TEST_COMMIT:?MMDB_TEST_COMMIT is not set in $PINS}"
: "${MMDB_TEST_SHA256:?MMDB_TEST_SHA256 is not set in $PINS}"
: "${MMDB_DECODER_SHA256:?MMDB_DECODER_SHA256 is not set in $PINS}"

base=https://raw.githubusercontent.com/maxmind/MaxMind-DB/$MMDB_TEST_COMMIT/test-data

# curl will not create the directory and fails with exit 23 if it is
# missing, which reads as a download error rather than as what it is.
dir=$(dirname "$OUT")
[ "$dir" = "$OUT" ] || mkdir -p "$dir"

"$SRC/ci/fetch-verify.sh" "$base/GeoIP2-City-Test.mmdb" "$MMDB_TEST_SHA256" "$OUT"
echo "ci/testdb.sh: $OUT"

decoder=$dir/MaxMind-DB-test-decoder.mmdb
"$SRC/ci/fetch-verify.sh" "$base/MaxMind-DB-test-decoder.mmdb" \
	"$MMDB_DECODER_SHA256" "$decoder"
echo "ci/testdb.sh: $decoder"
