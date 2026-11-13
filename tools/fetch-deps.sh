#!/usr/bin/env bash
# Resolve content-locked sources before compilation; tolerate transient upstream outages.
set -euo pipefail
for fetch_attempt in 1 2 3; do
    if "${ZIG:-zig}" build --fetch; then exit 0; fi
    if [[ "$fetch_attempt" == 3 ]]; then exit 1; fi
    sleep 10
done
