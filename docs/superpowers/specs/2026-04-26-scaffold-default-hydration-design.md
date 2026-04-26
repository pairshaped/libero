# Scaffold: SSR-hydrated SPA as the default for `libero new`

> **Bean:** libero-jqaj. Follow-up to libero-nm1e (isomorphic routing), now shipped.

## Goal

Update `libero new` to produce an SSR-hydrated SPA by default. The scaffolded skeleton compiles, runs with `gleam run -m libero -- build && gleam run`, server-renders HTML for `/`, and hydrates on the client. A `--no-client` flag opts out for server-only projects.

## Context

`libero/ssr.handle_request` and `libero/ssr.boot_script` shipped in libero 5.0. The `examples/ssr_hydration` example demonstrates the pattern. The current `libero new` scaffold predates these helpers: it produces a pure-SPA structure with a hard-coded inline `index.html` in the generated server entry. The bean tracks bringing the scaffold up to date.

## Scope

What changes:

1. Generated server entry (codegen): replace the hard-coded inline `index.html` fallthrough with an `ssr.handle_request` catch-all that dispatches via `page.load_page` and `page.render_page`. Existing routes for `/ws`, `/rpc`, and `/<client>/*` static files stay.
2. New scaffolded files: `shared/src/shared/router.gleam`, `shared/src/shared/views.gleam`, `src/server/page.gleam`.
3. Renamed scaffolded file: `shared/src/shared/messages.gleam` becomes `shared/src/shared/types.gleam`.
4. Updated scaffolded file: `clients/web/src/app.gleam` switches to `modem.init`, `decode_flags`, and the cross-target `views.view`. Adds `clients/web/src/flags_ffi.mjs`.
5. Updated handler: `src/server/handler.gleam` keeps the `ping` handler, now imports `PingError` from `shared/types`.
6. CLI flags: remove `--web`, add `--no-client`.
7. Tests: update `test/libero/cli_new_test.gleam` to verify the new default shape and the `--no-client` opt-out.

What does NOT change:

- The `examples/` directories. Existing examples already track the new patterns.
- The `libero/ssr` API. No new helpers needed.
- The `--database` flag and database scaffolding. Orthogonal to client/SSR.

## Out of scope

- Rewriting `docs/build-a-checklist-app.md`. That happens in a separate project once this scaffold has shipped.
- Making the scaffold a full demo app. The scaffold is a minimum-viable skeleton that compiles and runs. Pedagogical demos belong in `examples/` or guides.
- Adding `--no-ssr` or other axes of scaffold variation. Two shapes (default hydrated SPA, `--no-client`) cover the cases that exist today.

## File structure

Default `libero new myapp`:

```
myapp/
├── gleam.toml
├── shared/
│   ├── gleam.toml
│   └── src/shared/
│       ├── router.gleam       # Route enum, parse_route, route_to_path (cross-target)
│       ├── types.gleam        # Domain types used in handler signatures (cross-target)
│       └── views.gleam        # Model, Msg, view function (cross-target)
├── src/
│   ├── myapp.gleam            # Generated server entry: mist routes, calls page module
│   └── server/
│       ├── handler.gleam      # `ping` handler
│       ├── handler_context.gleam
│       └── page.gleam         # load_page + render_page (server-only SSR orchestration)
├── clients/
│   └── web/
│       ├── gleam.toml
│       └── src/
│           ├── app.gleam      # Lustre client: decode_flags + modem.init
│           └── flags_ffi.mjs  # FFI for reading window.__LIBERO_FLAGS__
└── test/
    └── myapp_test.gleam       # Starter test exercising `ping`
```

`libero new myapp --no-client`:

- No `clients/` directory.
- No `shared/router.gleam` or `shared/views.gleam`.
- No `src/server/page.gleam`.
- Server entry has no SSR catch-all. Falls through to a 404 response (matches the current behavior when a project is scaffolded without any client).
- Keeps `shared/types.gleam`, since handlers still need a place for domain types when called via HTTP `/rpc`.

## Per-module responsibilities

### `shared/router.gleam`

Owns the Route enum and bidirectional URL conversion. Cross-target so the server passes `router.parse_route` to `ssr.handle_request` and the client passes the same function to `modem.init`.

Starter content: `Route { Home }`, `parse_route` matches the empty path to `Home`, `route_to_path(Home) = "/"`.

### `shared/types.gleam`

Holds domain types that appear in handler signatures. Replaces the legacy `messages.gleam` name, which was a holdover from the pre-handler-as-contract era when "messages" meant manually-defined wire types.

Starter content: `pub type PingError { PingFailed }`. Purpose is to make the convention visible: domain error types live in shared/.

### `shared/views.gleam`

Cross-target view rendering. Holds `Model`, `Msg`, and `view`. The client adds an outer `ClientMsg` type wrapping `Msg` plus RPC variants.

Starter content:

- `Model(route: Route, ping_response: String)`. The `ping_response` field starts empty and gets filled by the client when the user clicks Ping.
- `Msg { UserClickedPing, NavigateTo(Route), NoOp }`.
- `view(model)` dispatches on `model.route`. The `Home` view renders the heading, a Ping button bound to `UserClickedPing`, and a paragraph showing `model.ping_response` (or a placeholder when empty).

### `src/server/page.gleam`

Server-only SSR orchestration. Two functions:

- `load_page(req, route, state)` returns `Result(Model, Response)`. Starter implementation is trivial: `Ok(Model(route:, ping_response: ""))`. No `ssr.call` demo.
- `render_page(route, model)` returns `Element(Msg)`. Wraps `views.view(model)` in `<html><head><body>` and appends `ssr.boot_script(client_module: "/web/web/app.mjs", flags: model)`.

The trivial `load_page` is intentional. Showing `ssr.call` in the scaffold would force a chain of demo data that's irrelevant the moment a user starts a real app. The shape is wired up; the user fills in the data fetch.

### `src/server/handler.gleam`

Unchanged from today except for the import: `import shared/types.{type PingError}` instead of `shared/messages`. Keeps `ping` returning `#(Result(String, PingError), HandlerContext)`. Codegen needs at least one handler, and `ping` doubles as the handler the scaffolded client actually calls.

### `clients/web/src/app.gleam`

Hydrating Lustre client. Pattern matches the example:

- `main()` calls `lustre.application(init, update, view_wrap)` and starts on `#app` with `get_flags()` as the flags.
- `init(flags)` calls `decode_flags(flags)`. On Ok, returns the decoded `Model` and `modem.init(on_url_change)`. On Error, panics with a message that points the user at `ssr.boot_script`.
- `on_url_change(uri)` runs `router.parse_route` and emits `NavigateTo(route)` or `NoOp`.
- `update` handles `ViewMsg(UserClickedPing)` (issues `rpc.ping(on_response: GotPing)`), `ViewMsg(NavigateTo(route))` (updates `model.route`), `ViewMsg(NoOp)` (no-op), and `GotPing(rd)` (writes the response text into `model.ping_response`).
- `view_wrap` lifts `views.view(model): Element(Msg)` to `Element(ClientMsg)` via `element.map(ViewMsg)`.
- FFI: `get_flags()` reads `window.__LIBERO_FLAGS__` from `flags_ffi.mjs`.

### `src/myapp.gleam` (generated server entry)

Codegen produces the server entry at scaffold time and never overwrites it (existing `write_if_missing` behavior). Routing case stays:

```gleam
case req.method, request.path_segments(req) {
  _, ["ws"] -> ws.upgrade(...)
  http.Post, ["rpc"] -> handle_rpc(...)
  _, ["web", ..path] -> serve_file(...)
  _, _ -> ssr.handle_request(
    req:,
    parse: router.parse_route,
    load: page.load_page,
    render: page.render_page,
    state:,
  )
}
```

When `--no-client` is set, the `["web", ..path]` arm and the SSR fallthrough are both dropped. Fallthrough becomes `_, _ -> response.new(404) |> ...`.

## CLI changes

`src/libero/cli.gleam` and `src/libero/cli/new.gleam`:

- Remove `--web`. The flag was the explicit way to add a JS client at scaffold time. With SSR-hydrated SPA as the default, `--web` is implicit.
- Add `--no-client`. Inverts the default: skip the JS client and the SSR wiring.

`scaffold` function signature changes from `(path, database, web)` to `(path, database, no_client)`.

## Test coverage

`test/libero/cli_new_test.gleam` updates:

- Existing `scaffold_project_test`: drop the `web: False` argument. Assert the new default files exist (`shared/src/shared/router.gleam`, `shared/src/shared/views.gleam`, `shared/src/shared/types.gleam`, `src/server/page.gleam`, `clients/web/src/app.gleam`, `clients/web/src/flags_ffi.mjs`). Assert that `shared/src/shared/messages.gleam` does NOT exist.
- New `scaffold_no_client_test`: passes `no_client: True`. Assert that `clients/`, `shared/router.gleam`, `shared/views.gleam`, and `src/server/page.gleam` are absent. Assert that `shared/types.gleam` and `src/server/handler.gleam` are present.
- Existing database scaffold tests (`scaffold_pg_test`, `scaffold_sqlite_test`): drop `web: False` argument. Verify they still produce the new default file shape.
- New `scaffold_runs_test` (optional, slower): scaffolds, runs `libero build`, asserts the generated dispatch and SSR call sites compile. Skip if cycle time becomes a problem; existing `gen_run_test` covers most of this already.

## Behavior on first `gleam run`

A user who runs `libero new myapp && cd myapp && gleam run -m libero -- build && gleam run`:

1. Server starts on port 8080.
2. Visiting `http://localhost:8080/` returns SSR HTML: a heading, a Ping button, and a placeholder paragraph. The page is fully styled-and-laid-out before any JavaScript runs.
3. The client boots, decodes flags, hydrates the existing DOM (no flicker, no remount).
4. Clicking the Ping button issues an RPC call. The response replaces the placeholder text with "Server says: pong".

Failure modes the scaffold must handle gracefully:

- `decode_flags` Error: the client panics with a clear message. Users see this if they accidentally remove `ssr.boot_script` or load the client outside of an SSR-rendered page.
- Bad URLs at navigation time: `parse_route` returns `Error(Nil)`, `on_url_change` emits `NoOp`. The browser's URL changes but the model doesn't. Better than panicking.

## Migration

Libero 5.0 has not been published to hex. There are no external users on the current scaffold to migrate. The change ships as part of whatever the next published version is.

`examples/ssr_hydration` already follows the new pattern. Existing internal projects scaffolded against the old `libero new` keep their original `main.gleam` because codegen uses `write_if_missing` for the server entry. They are not auto-migrated; if the maintainer wants SSR they have to update the file by hand against the new template. That is acceptable, since the affected projects are countable on one hand and the rewrite is small.

## Risks

- **Codegen complexity**: the generated server entry now imports `libero/ssr`, the `router` module path from shared, and the `page` module from server. The codegen template grows. Mitigation: keep the template flat, no fancy splicing, and rely on existing `gen_run_test` to catch regressions.
- **Cross-target compile cost**: `shared/views.gleam` now depends on lustre. The shared package compiles on both Erlang and JavaScript. Existing examples already do this and the build cost is small, but worth verifying the scaffold's first-build time is reasonable on a clean machine.
- **Naming overlap**: `shared/router.gleam` (route definitions) and `src/server/router.gleam` (HTTP routing, the curling-style pattern users coming from non-hydrated apps may be used to) describe related but different things. The scaffold ships only the first; the second is an internal convention for users who want to factor out their server entry's routing case as their app grows. Worth a sentence in the README so the distinction is visible.

## Open questions for the implementation plan

- Exact wording of comments in scaffolded files. The user prefers minimal comments. Settle on a per-file budget (likely zero or one short line) when writing the plan.
- Whether `shared/types.gleam` ships empty or with `PingError`. Spec assumes it ships with `PingError` because `ping` references it. Confirm during implementation.
- Whether the generated server entry's import block is hand-formatted by codegen or runs through `gleam format` after write. Existing codegen runs `gleam format` on `.gleam` writes, so this should already work; verify.
