#!/usr/bin/env bash
# Builds and tests the iso_routing fixture on both Erlang and JS targets.
# Stages to /tmp first to avoid the parent project's gleam compiler picking
# up fixture .gleam files. Source files are stored as .gleam.template at rest
# for the same reason.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE_SRC="$ROOT_DIR/test/fixtures/iso_routing"
STAGE_ROOT="${TMPDIR:-/tmp}/libero-iso-routing"
STAGED="$STAGE_ROOT/iso_routing"

if [ "${1:-}" = "--clean" ]; then
  rm -rf "$STAGE_ROOT"
fi

# Fresh staging dir each run.
rm -rf "$STAGED"
mkdir -p "$STAGED/src" "$STAGED/test" "$STAGED/shared/src" "$STAGED/clients/web/src"

# Copy gleam.toml files.
cp "$FIXTURE_SRC/gleam.toml" "$STAGED/gleam.toml"
cp "$FIXTURE_SRC/shared/gleam.toml" "$STAGED/shared/gleam.toml"
cp "$FIXTURE_SRC/clients/web/gleam.toml" "$STAGED/clients/web/gleam.toml"

# Copy source files (templates) into the proper layout.
cp -R "$FIXTURE_SRC/fixture_src/." "$STAGED/src/"
cp -R "$FIXTURE_SRC/test_src/." "$STAGED/test/"
cp -R "$FIXTURE_SRC/shared_src/." "$STAGED/shared/src/"
cp -R "$FIXTURE_SRC/client_src/." "$STAGED/clients/web/src/"

# Rename .gleam.template -> .gleam in the staged copy.
find "$STAGED" -name '*.gleam.template' -exec sh -c '
  for path do
    mv "$path" "${path%.template}"
  done
' sh {} +

# Patch the libero path-dep in the staged copy if present (none in iso_routing,
# but match wire_e2e pattern in case future tasks add it).
if grep -q 'libero = { path' "$STAGED/gleam.toml" 2>/dev/null; then
  perl -0pi -e "s#libero = \\{ path = \"[^\"]+\" \\}#libero = { path = \"$ROOT_DIR\" }#g" \
    "$STAGED/gleam.toml"
fi

cd "$STAGED"

echo "==> Building shared on Erlang target"
(cd shared && gleam build --target erlang)

echo "==> Building shared on JavaScript target"
(cd shared && gleam build --target javascript)

echo "==> Running BEAM tests"
gleam test

echo "==> Building JS web crate"
cd clients/web
gleam build --target javascript

echo "==> Running JS test runner"
output="$(gleam run -m web_test_runner --target javascript 2>&1)"
echo "$output"
echo "$output" | grep -q "^OK$" || {
  echo "JS test runner did not print OK"
  exit 1
}

echo "==> All cross-target tests passed"
