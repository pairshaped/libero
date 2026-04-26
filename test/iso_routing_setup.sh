#!/usr/bin/env bash
# Builds and tests the iso_routing fixture on both Erlang and JS targets.
# Used by CI to prove the shared parse_route compiles and runs identically.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURE="$SCRIPT_DIR/fixtures/iso_routing"

cd "$FIXTURE"

# Remove stale build artifacts that cause Erlang module name collisions.
# Gleam scans the entire libero source tree (including sibling fixtures)
# when resolving the libero path dep, so other fixtures' build dirs must
# also be cleared before a clean BEAM compile.
rm -rf build shared/build clients/web/build
find "$(dirname "$FIXTURE")" -maxdepth 2 -name "build" -type d ! -path "$FIXTURE/*" -exec rm -rf {} + 2>/dev/null || true

echo "==> Running BEAM tests (compiles shared as Erlang path dep)"
gleam test

echo "==> Building JS web crate"
cd clients/web
gleam build --target javascript

echo "==> Running JS test runner"
output="$(gleam run --target javascript -m web_test_runner 2>&1)"
echo "$output"
echo "$output" | grep -q "^OK$" || {
  echo "JS test runner did not print OK"
  exit 1
}

echo "==> All cross-target tests passed"
