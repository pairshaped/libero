---
# libero-20zx
title: Wire E2E test harness
status: completed
type: feature
priority: normal
created_at: 2026-04-25T16:37:10Z
updated_at: 2026-04-25T17:31:47Z
---

Implement the wire end-to-end test harness from docs/superpowers/specs/2026-04-25-wire-e2e-tests-design.md.

- [x] Verify path-dep consumer can run `gleam run -m libero -- gen`
- [x] Create implementation plan
- [x] Scaffold wire_e2e fixture
- [x] Add setup script with clean support and batched manifests
- [x] Add module-load smoke test
- [x] Add first decode, encode, and dispatch cases
- [x] Expand full matrix and wire JS test runner

## Summary of Changes

- Added a staged wire_e2e fixture and setup script with --clean support.
- Added batched BEAM manifests for decode and dispatch cases.
- Added JS E2E coverage for module loading, decode, encode, and dispatch.
- Fixed generated response decoders for nested Dict return types.
- Fixed runtime handling for raw BINARY_EXT typed strings/BitArrays and Gleam stdlib Dict encoding.
