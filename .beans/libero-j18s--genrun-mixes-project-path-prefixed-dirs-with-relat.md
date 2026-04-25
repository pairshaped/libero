---
# libero-j18s
title: gen.run mixes project_path-prefixed dirs with relative file writes
status: completed
type: bug
priority: high
created_at: 2026-04-25T21:22:02Z
updated_at: 2026-04-25T21:27:33Z
---

`cli/gen.run(project_path:)` accepts a project path but doesn't apply
it consistently across the codegen pipeline.

In `run_endpoint_client_codegen` (and the classic equivalent), directory
creation uses `project_path <> "/" <> config.server_generated`
(correct), but the subsequent `codegen.write_endpoint_dispatch(server_generated: config.server_generated, ...)`
passes the bare relative path. Files end up at `CWD/src/server/generated/dispatch.gleam`
instead of `<project_path>/src/server/generated/dispatch.gleam`.

Same pattern for `write_endpoint_client_stubs`, `write_websocket`,
`write_atoms`, `write_config`, `write_decoders_gleam`,
`write_decoders_ffi`, `write_ssr_flags`, and `write_main` in
`generate_main`.

Why it's hidden: the `libero gen` CLI is always invoked from the
project root with `project_path = "."`, so the relative paths
happen to land in the right place. Any other caller
(integration tests, programmatic embedding) writes files to
the wrong location.

Discovered while writing convention-switch tests for I7 — the test
fixture at `build/.test_gen_run_*` triggered file writes inside
libero's own `src/` tree, which then broke `gleam test` on the next
run.

Fix: prepend project_path to every output path passed into codegen.
Either prefix at the call site or build a project-prefixed Config
once and thread it through.
