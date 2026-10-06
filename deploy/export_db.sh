#!/bin/sh
# Periodically export a CONSISTENT single-file snapshot of the WAL-mode garmin.db
# using `VACUUM INTO`, so an HTTP client only ever fetches a clean, up-to-date copy.
#
# - Source DB (read):   $SRC   (fetcher keeps writing to this in WAL mode)
# - Export target:      $DST   (what busybox httpd serves)
# - Interval:           $INTERVAL_SECONDS (default 3600 = 1 hour)
#
# VACUUM INTO reads a consistent snapshot without disturbing the writer, and the
# output is a standalone .db with no -wal/-shm needed.

set -eu

SRC="${SRC:-/data/garmin.db}"
DST="${DST:-/export/garmin_export.db}"
TMP="${DST}.tmp"
INTERVAL_SECONDS="${INTERVAL_SECONDS:-3600}"

echo "[export] src=$SRC dst=$DST interval=${INTERVAL_SECONDS}s"

while true; do
    if [ -f "$SRC" ]; then
        # Export a consistent snapshot to a temp file, then atomically move into place
        # so the HTTP server never serves a half-written file.
        if python -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute(\"VACUUM INTO '\"+sys.argv[2]+\"'\"); c.close()" "$SRC" "$TMP"; then
            mv -f "$TMP" "$DST"
            echo "[export] $(date -u +%FT%TZ) wrote $DST ($(wc -c < "$DST") bytes)"
        else
            echo "[export] $(date -u +%FT%TZ) ERROR: VACUUM INTO failed, keeping previous export"
            rm -f "$TMP" 2>/dev/null || true
        fi
    else
        echo "[export] $(date -u +%FT%TZ) WARN: source $SRC not found, skipping"
    fi
    sleep "$INTERVAL_SECONDS"
done
