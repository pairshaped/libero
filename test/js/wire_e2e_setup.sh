#!/usr/bin/env sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
FIXTURE_SRC="$ROOT_DIR/test/fixtures/wire_e2e"
STAGE_ROOT="${TMPDIR:-/tmp}/libero-wire-e2e"
STAGED_FIXTURE="$STAGE_ROOT/wire_e2e"
BUILD_ROOT_FILE="$ROOT_DIR/test/js/.wire_e2e_build_root"
DECODE_MANIFEST="$ROOT_DIR/test/js/.wire_e2e_decode_manifest.json"
DISPATCH_MANIFEST="$ROOT_DIR/test/js/.wire_e2e_dispatch_manifest.json"

if [ "${1:-}" = "--clean" ]; then
  rm -rf "$STAGE_ROOT"
  rm -f "$BUILD_ROOT_FILE" "$DECODE_MANIFEST" "$DISPATCH_MANIFEST"
fi

rm -rf "$STAGED_FIXTURE"
mkdir -p "$STAGED_FIXTURE"

# Three-peer layout: $STAGED/server/, $STAGED/shared/, $STAGED/clients/web/.
mkdir -p "$STAGED_FIXTURE/server/src" "$STAGED_FIXTURE/shared/src" "$STAGED_FIXTURE/clients/web/src"
cp "$FIXTURE_SRC/gleam.toml" "$STAGED_FIXTURE/server/gleam.toml"
cp -R "$FIXTURE_SRC/server_src/." "$STAGED_FIXTURE/server/src/"
cp -R "$FIXTURE_SRC/shared/." "$STAGED_FIXTURE/shared/"
cp -R "$FIXTURE_SRC/shared_src/." "$STAGED_FIXTURE/shared/src/"
cp -R "$FIXTURE_SRC/clients/web/." "$STAGED_FIXTURE/clients/web/"
cp -R "$FIXTURE_SRC/client_src/." "$STAGED_FIXTURE/clients/web/src/"

find "$STAGED_FIXTURE" -name '*.gleam.template' -exec sh -c '
  for path do
    mv "$path" "${path%.template}"
  done
' sh {} +

perl -0pi -e "s#libero = \\{ path = \"[^\"]+\" \\}#libero = { path = \"$ROOT_DIR\" }#g" \
  "$STAGED_FIXTURE/server/gleam.toml"
perl -0pi -e "s#libero = \\{ path = \"[^\"]+\" \\}#libero = { path = \"$ROOT_DIR\" }#g" \
  "$STAGED_FIXTURE/clients/web/gleam.toml"

(
  cd "$STAGED_FIXTURE/server"
  gleam run -m libero -- gen
  gleam build --target erlang
)

(
  cd "$STAGED_FIXTURE/clients/web"
  gleam build --target javascript
)

printf '%s\n' "$STAGED_FIXTURE" > "$BUILD_ROOT_FILE"

erl -noshell -eval "$(cat "$ROOT_DIR/test/js/wire_e2e_decode_manifest.escript")" > "$DECODE_MANIFEST"

ERL_EBINS=$(find "$STAGED_FIXTURE/server/build/dev/erlang" -path '*/ebin' -type d | tr '\n' ' ')
erl -noshell -pa $ERL_EBINS -eval "$(cat "$ROOT_DIR/test/js/wire_e2e_dispatch_manifest.escript")" > "$DISPATCH_MANIFEST"
