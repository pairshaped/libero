---
# libero-xy3k
title: 'Dispatch: add catch-all arm for unknown function and unregistered variant'
status: todo
type: feature
created_at: 2026-04-25T20:00:00Z
updated_at: 2026-04-25T20:00:00Z
---

The dispatch codegen's inner `case typed_msg` is exhaustive for known variants with no catch-all. Unmatched messages (unknown function, unregistered variant within a known module) crash at the Erlang level instead of returning graceful `Error(UnknownFunction(...))` or equivalent.

Needed changes:
- Add a catch-all arm to the typed message case in generated dispatch
- Wire E2E dispatch test already has the test cases written, gated behind comments
- Unblocks two dispatch error test cases in `wire_e2e_dispatch_test.mjs`
