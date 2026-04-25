#!/usr/bin/env sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT_DIR"

test/js/wire_e2e_setup.sh

node test/js/etf_codec_test.mjs
node test/js/decoders_prelude_test.mjs
node test/js/wire_e2e_module_load_test.mjs
node test/js/wire_e2e_decode_test.mjs
node test/js/wire_e2e_encode_test.mjs
node test/js/wire_e2e_dispatch_test.mjs
