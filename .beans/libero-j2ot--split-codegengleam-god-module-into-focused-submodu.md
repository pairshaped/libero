---
# libero-j2ot
title: Split codegen.gleam god-module into focused submodules
status: todo
type: task
priority: normal
created_at: 2026-04-26T20:07:16Z
updated_at: 2026-04-26T20:07:16Z
---

`src/libero/codegen.gleam` is 1461 lines and builds Gleam source via raw string concatenation. No AST builder, no helpers for emitting patterns, just `<>` joins everywhere. Works today because inputs are validated upstream, but every change is risky and diffs are hard to review.

## Suggested split

- `codegen_dispatch.gleam` — server-side dispatch generation
- `codegen_decoders.gleam` — typed decoder emission (currently the most string-heavy section)
- `codegen_stubs.gleam` — per-client RPC stub generation
- `codegen_server.gleam` — generated server entry (`main`, mist setup)

## Stretch

Introduce a tiny `Doc`-style code builder so emitted Gleam can be tested structurally instead of via `string.contains`. This would also let us replace the substring-matching tests in `endpoint_dispatch_test.gleam`, `typed_decoder_codegen_test.gleam`, and `wire_custom_type_test.gleam`.

## Why now

Surfaced in the project-wide code review (2026-04-26). Not blocking any feature, but the longer this grows, the harder the split. Pairs well with future handler-shape additions which would otherwise pile more `<>` joins into the same file.
