# Wire E2E Tests Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Build a checked-in fixture and JS E2E test harness that loads real generated client artifacts and verifies BEAM-to-JS decode, JS-to-BEAM encode, and generated dispatch routing.

**Architecture:** A fixture Gleam project under `test/fixtures/wire_e2e/` mirrors `examples/todos`, uses libero as a path dependency, and is copied to an external staging directory for codegen/build. Shell helpers build the staged fixture and generate batched manifests so Node tests avoid per-case BEAM cold starts.

**Tech Stack:** Gleam, Erlang/OTP, POSIX shell, Node ESM tests, Beans for task tracking.

---

### Task 1: Preflight Path-Dependency CLI

**Files:**
- Temporary only: `/tmp/libero-preflight/**`
- Modify: `.beans/libero-20zx--wire-e2e-test-harness.md`

- [x] Create the smallest endpoint-convention fixture under `/tmp/libero-preflight`.
- [x] Run `gleam run -m libero -- gen` from `/tmp/libero-preflight`.
- [x] Confirm it writes generated server/client files with no setup-script structural change needed.
- [x] Mark the Beans checklist item complete.

### Task 2: Fixture Skeleton

**Files:**
- Create: `test/fixtures/wire_e2e/gleam.toml`
- Create: `test/fixtures/wire_e2e/shared/gleam.toml`
- Create: `test/fixtures/wire_e2e/shared_src/shared/types.gleam.template`
- Create: `test/fixtures/wire_e2e/server_src/server/handler_context.gleam.template`
- Create: `test/fixtures/wire_e2e/server_src/server/handler.gleam.template`
- Create: `test/fixtures/wire_e2e/clients/web/gleam.toml`
- Create: `test/fixtures/wire_e2e/client_src/app.gleam.template`
- Modify: `.gitignore`
- Modify: `.beans/libero-20zx--wire-e2e-test-harness.md`

- [x] Add the fixture package with `libero = { path = "../../.." }`.
- [x] Add the shared package with the full type matrix from the spec.
- [x] Add all 22 handler endpoints.
- [x] Add a minimal JS client app that imports generated messages.
- [x] Ignore fixture generated source, manifest files, and build-root marker files.
- [x] Do not build the fixture in place under the repo root.
- [x] Mark the Beans fixture checklist item complete.

### Task 3: Setup And Batched Manifests

**Files:**
- Create: `test/js/wire_e2e_setup.sh`
- Create: `test/fixtures/wire_e2e/test_support/wire_e2e_manifest.erl`
- Modify: `.beans/libero-20zx--wire-e2e-test-harness.md`

- [x] Write `wire_e2e_setup.sh` with normal and `--clean` modes.
- [x] Make setup copy fixture sources to an external staging directory.
- [x] Make setup rewrite staged `libero` path dependencies to the absolute repo root.
- [x] Make setup run codegen, server build, client build, then manifest generation in the staged fixture.
- [x] Make setup write `test/js/.wire_e2e_build_root`.
- [x] Write one Erlang helper that emits `test/js/.wire_e2e_decode_manifest.json`.
- [x] Write dispatch cases into `test/js/.wire_e2e_dispatch_manifest.json`.
- [x] Run `test/js/wire_e2e_setup.sh --clean`.
- [x] Mark the Beans setup checklist item complete.

### Task 4: Module Load Smoke Test

**Files:**
- Create: `test/js/wire_e2e_module_load_test.mjs`
- Modify: `test/run_js_tests.sh`
- Modify: `.beans/libero-20zx--wire-e2e-test-harness.md`

- [x] Add a Node ESM test that imports compiled `messages.mjs`, `rpc_decoders.mjs`, `rpc_decoders_ffi.mjs`, and `app.mjs`.
- [x] Verify it fails before setup artifacts exist.
- [x] Verify it passes after `wire_e2e_setup.sh`.
- [x] Add it to `test/run_js_tests.sh`.
- [x] Mark the Beans module-load checklist item complete.

### Task 5: First Decode, Encode, And Dispatch Tests

**Files:**
- Create: `test/js/wire_e2e_decode_test.mjs`
- Create: `test/js/wire_e2e_encode_test.mjs`
- Create: `test/js/wire_e2e_dispatch_test.mjs`
- Modify: `test/run_js_tests.sh`
- Modify: `.beans/libero-20zx--wire-e2e-test-harness.md`

- [x] Decode test: assert BEAM `Ok(Int)` decodes through `decode_response_echo_int`.
- [x] Encode test: assert JS `WithFloats(2.0, 3.0, "whole")` encodes through request-envelope path and decodes on BEAM with float fields preserved.
- [x] Dispatch test: assert `echo_int` returns `5` and `echo_int_negated` returns `-5`.
- [x] Add the tests to `test/run_js_tests.sh`.
- [x] Mark the Beans first-case checklist item complete.

### Task 6: Full Matrix And CI Runner

**Files:**
- Modify: `test/fixtures/wire_e2e/test_support/wire_e2e_manifest.erl`
- Modify: `test/js/wire_e2e_decode_test.mjs`
- Modify: `test/js/wire_e2e_encode_test.mjs`
- Modify: `test/js/wire_e2e_dispatch_test.mjs`
- Modify: `test/run_js_tests.sh`
- Modify: `.beans/libero-20zx--wire-e2e-test-harness.md`

- [x] Expand Pattern A across all endpoints and required edge cases.
- [x] Expand Pattern B across the encode matrix.
- [x] Add dispatch unknown-function and malformed-envelope cases.
- [x] Run `gleam test`.
- [x] Run `test/run_js_tests.sh`.
- [x] Run `test/js/wire_e2e_setup.sh --clean && test/run_js_tests.sh`.
- [x] Add a `## Summary of Changes` section to the bean.
- [x] Mark the bean completed only when all checklist items are complete.
