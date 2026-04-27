# Libero project layout: three-peer monorepo with examples-as-templates

> **Bean:** libero-jqaj. Originally scoped to "make SSR-hydrated SPA the scaffold default." Through brainstorming this expanded into a layout-and-tooling rework. The bean description should be updated.

## Goal

Restructure libero projects to follow Lustre's recommended three-peer monorepo layout (`server/`, `shared/`, `clients/`). Use libero's own `examples/` directory as the canonical starter set: scaffolding a new project becomes copying an example. Replace the bespoke `libero new` CLI codegen with a hosted shell script that fetches and renames an example.

## Context

Libero today puts the server package at the project root. `clients/` and `shared/` are subdirectories. This was the path of least resistance — Gleam needs a runnable root package, and the server is the obvious thing to make runnable. But it has costs:

1. **Layout misleads about importance.** `shared/` is the cross-target contract that both server and client depend on. Putting it in a subdir signals "auxiliary helper" when it's structurally as load-bearing as the server.
2. **Diverges from Lustre's official guide.** Lustre docs recommend three peer packages at root. New users coming from Lustre encounter unfamiliar shape.
3. **`libero new` has a chicken-and-egg problem.** Invoked as `gleam run -m libero -- new <name>`, it requires libero to already be a dep of a Gleam project. Brand-new users don't have one.
4. **Scaffold templates and example apps duplicate effort.** The CLI codegen has hand-written file content; `examples/` directories have working apps. They drift.

Pre-launch is the cheapest moment to fix all four.

## Scope

What changes:

1. **Layout.** Server moves out of the root into `server/`. Sibling peers: `server/`, `shared/`, `clients/`. No top-level `gleam.toml`.
2. **Codegen paths.** Libero's codegen and config defaults update to write to `src/generated/` (inside `server/`), `../clients/<name>/src/generated/`, and read from `../shared/src/shared/`. Paths become relative to libero's cwd, which is always `server/`.
3. **Default example.** New `examples/default/` is the canonical minimal SSR-hydrated SPA. Doubles as the starter shape.
4. **Existing example migrates.** `examples/todos/` moves to the new three-peer layout. (`examples/ssr_hydration/` was already deleted.)
5. **Scaffolding via shell script.** New `bin/new` in the libero repo: a `curl | sh`-style script that downloads the libero tarball, extracts an example into a target directory, renames the example name to the user's project name across `gleam.toml` files, and runs `git init`. Replaces the bespoke `libero new` CLI codegen path.
6. **Per-project bin scripts.** Each scaffolded project ships `bin/dev` and `bin/test` as the entry points for daily workflow. Wraps the `cd server && ...` ceremony.
7. **CLI collapse.** Libero's CLI becomes single-purpose: invoking `gleam run -m libero` generates code. No subcommands, no flags. Mirrors marmot. The `new`, `add`, `build`, `gen` distinctions all go away; `libero` either generates or it doesn't. Argument parsing in `cli.gleam` is removed; `cli/new.gleam`, `cli/add.gleam`, `cli/templates.gleam`, `cli/parse_database.gleam` are deleted.
8. **README and llms.txt updates.** New "getting started" using `curl | sh`. Layout section reflects the three-peer shape.
9. **Tests.** Scaffold tests in `cli_new_test.gleam` are deleted (the CLI scaffold path goes away). New tests verify `examples/default/` builds and runs end-to-end.

What does NOT change:

- The `libero/ssr` API. Helpers shipped in libero-nm1e remain unchanged.
- The handler-as-contract codegen. Type scanning, dispatch generation, websocket generation are unchanged at the algorithm level. Only the file paths they read/write change.
- The `--database pg | sqlite` scaffold variation. With examples-as-templates, this becomes "pick a different example" (`examples/default-pg/`, `examples/default-sqlite/`), or accept that database setup is a manual step the user does after copying the default.

## Out of scope

- Rewriting `docs/build-a-checklist-app.md`. Separate project, happens after this lands.
- Migrating curling/v3 to the new layout. Owned by user, happens after libero ships.
- Distributing libero as a standalone binary or via package managers (brew, mise). Future bean.
- Hosting `libero.run` or any custom domain. The script is served from `raw.githubusercontent.com/pairshaped/libero/main/bin/new`. Custom domain is a future bean.
- Database scaffold variations. The default example doesn't pre-wire pg or sqlite. Users add a database manually or pick a different example once we ship one.
- Multi-client scaffolding (`libero add cli --target erlang`). Adding a second client is a manual operation: create the directory, write its `gleam.toml`, register it in `server/gleam.toml`'s `[tools.libero.clients.X]`. Documented in README.

## File layout

A scaffolded `my_app` looks like:

```
my_app/
├── .gitignore
├── README.md
├── bin/
│   ├── dev               # codegen + run server
│   └── test              # run server tests
├── server/
│   ├── gleam.toml        # target=erlang, [tools.libero] config, libero+mist+lustre deps
│   ├── manifest.toml
│   └── src/
│       ├── server.gleam              # entry point, customizable, never overwritten
│       ├── handler.gleam             # ping handler
│       ├── handler_context.gleam
│       ├── page.gleam                # load_page + render_page (SSR orchestration)
│       └── generated/                # codegen output (dispatch, websocket)
├── shared/
│   ├── gleam.toml        # no target (cross-compiles)
│   ├── manifest.toml
│   └── src/shared/
│       ├── router.gleam              # Route, parse_route, route_to_path
│       ├── types.gleam               # PingError (domain types)
│       └── views.gleam               # Model, Msg, view function
└── clients/
    └── web/
        ├── gleam.toml    # target=javascript, lustre+modem deps
        ├── manifest.toml
        └── src/
            ├── app.gleam             # Lustre client: decode_flags + modem.init
            └── flags_ffi.mjs         # FFI for window.__LIBERO_FLAGS__
```

Per-package gleam.toml summaries:

- `server/gleam.toml`: target=erlang, deps = libero, mist, lustre, gleam_http, shared (path: `../shared`). Holds `[tools.libero]` config including `shared_src_dir = "../shared/src/shared"` and `[tools.libero.clients.web]` with target=javascript and path=`../clients/web`.
- `shared/gleam.toml`: no target (compiles to both). Deps = lustre, gleam_stdlib, libero (for `libero/ssr` types used in views).
- `clients/web/gleam.toml`: target=javascript, deps = lustre, modem, libero, shared (path: `../../shared`).

## The default example (`examples/default/`)

Minimum viable SSR-hydrated SPA. Renders "Hello from default" plus a Ping button on the server, hydrates on the client, button click calls `ping` handler via RPC and shows the response.

### `shared/src/shared/router.gleam`

```gleam
import gleam/uri.{type Uri}

pub type Route {
  Home
}

pub fn parse_route(uri: Uri) -> Result(Route, Nil) {
  case uri.path_segments(uri.path) {
    [] -> Ok(Home)
    _ -> Error(Nil)
  }
}

pub fn route_to_path(route: Route) -> String {
  case route {
    Home -> "/"
  }
}
```

### `shared/src/shared/types.gleam`

```gleam
pub type PingError {
  PingFailed
}
```

### `shared/src/shared/views.gleam`

```gleam
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import shared/router.{type Route, Home}

pub type Model {
  Model(route: Route, ping_response: String)
}

pub type Msg {
  UserClickedPing
  NavigateTo(Route)
  NoOp
}

pub fn view(model: Model) -> Element(Msg) {
  case model.route {
    Home -> home_view(model.ping_response)
  }
}

fn home_view(ping_response: String) -> Element(Msg) {
  html.div([], [
    html.h1([], [html.text("Hello from default")]),
    html.button([event.on_click(UserClickedPing)], [html.text("Ping")]),
    case ping_response {
      "" -> html.p([], [html.text("Click to ping the server.")])
      msg -> html.p([], [html.text("Server says: " <> msg)])
    },
  ])
}
```

### `server/src/handler.gleam`

```gleam
import handler_context.{type HandlerContext}
import shared/types.{type PingError}

pub fn ping(
  state state: HandlerContext,
) -> #(Result(String, PingError), HandlerContext) {
  #(Ok("pong"), state)
}
```

Note: imports use `handler_context` (no `server/` prefix) because we're inside the server package now.

### `server/src/page.gleam`

```gleam
import gleam/http/request.{type Request}
import gleam/http/response
import handler_context.{type HandlerContext}
import libero/ssr
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import mist.{type Connection, type ResponseData}
import shared/router.{type Route}
import shared/views.{type Model, type Msg, Model}

pub fn load_page(
  _req: Request(Connection),
  route: Route,
  _state: HandlerContext,
) -> Result(Model, response.Response(ResponseData)) {
  Ok(Model(route:, ping_response: ""))
}

pub fn render_page(_route: Route, model: Model) -> Element(Msg) {
  html.html([attribute.attribute("lang", "en")], [
    html.head([], [
      html.meta([attribute.attribute("charset", "utf-8")]),
      html.meta([
        attribute.name("viewport"),
        attribute.attribute("content", "width=device-width, initial-scale=1"),
      ]),
      html.title([], "default"),
    ]),
    html.body([], [
      html.div([attribute.id("app")], [views.view(model)]),
      ssr.boot_script(client_module: "/web/web/app.mjs", flags: model),
    ]),
  ])
}
```

### `server/src/server.gleam` (entry, generated by codegen)

Mist setup: routes `/ws` to websocket, `POST /rpc` to HTTP RPC, `/web/*` to static files for the JS client, and a catch-all `ssr.handle_request(parse: router.parse_route, load: page.load_page, render: page.render_page, state:)`.

### `clients/web/src/app.gleam`

```gleam
import generated/messages as rpc
import gleam/dynamic.{type Dynamic}
import gleam/uri.{type Uri}
import libero/remote_data.{type RemoteData, Success}
import libero/ssr as libero_ssr
import lustre
import lustre/effect.{type Effect}
import lustre/element
import modem
import shared/router
import shared/types.{type PingError}
import shared/views.{type Model, type Msg, Model, NavigateTo, NoOp, UserClickedPing}

pub type ClientMsg {
  ViewMsg(Msg)
  GotPing(RemoteData(String, PingError))
}

pub fn main() {
  let app = lustre.application(init, update, view_wrap)
  let assert Ok(_) = lustre.start(app, "#app", get_flags())
  Nil
}

fn init(flags: Dynamic) -> #(Model, Effect(ClientMsg)) {
  let model = case libero_ssr.decode_flags(flags) {
    Ok(m) -> m
    Error(_) ->
      panic as "failed to decode SSR flags — was ssr.boot_script called on the server?"
  }
  #(model, modem.init(on_url_change))
}

fn on_url_change(uri: Uri) -> ClientMsg {
  case router.parse_route(uri) {
    Ok(route) -> ViewMsg(NavigateTo(route))
    Error(_) -> ViewMsg(NoOp)
  }
}

fn update(model: Model, msg: ClientMsg) -> #(Model, Effect(ClientMsg)) {
  case msg {
    ViewMsg(UserClickedPing) -> #(model, rpc.ping(on_response: GotPing))
    ViewMsg(NavigateTo(route)) -> #(Model(..model, route:), effect.none())
    ViewMsg(NoOp) -> #(model, effect.none())
    GotPing(Success(response)) -> #(
      Model(..model, ping_response: response),
      effect.none(),
    )
    GotPing(_) -> #(
      Model(..model, ping_response: "ping failed"),
      effect.none(),
    )
  }
}

fn view_wrap(model: Model) -> element.Element(ClientMsg) {
  views.view(model) |> element.map(ViewMsg)
}

@external(javascript, "./flags_ffi.mjs", "getFlags")
fn get_flags() -> Dynamic {
  panic as "get_flags requires a browser"
}
```

### `bin/dev`

```bash
#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$DIR/server"
gleam run -m libero
gleam run
```

### `bin/test`

```bash
#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$DIR/server" && gleam test
```

## The `bin/new` scaffolding script (libero repo)

Path: `bin/new` in the libero repo (not in scaffolded apps). Distributed via `raw.githubusercontent.com/pairshaped/libero/main/bin/new`.

Behavior:
1. Take two args: project name (required), example name (optional, defaults to `default`).
2. Download `https://github.com/pairshaped/libero/archive/main.tar.gz`.
3. Extract `libero-main/examples/<example_name>/` to `./<project_name>/`, stripping the leading path components.
4. Walk all `gleam.toml` files in the new project, replace `name = "<example_name>"` with `name = "<project_name>"` and any `path = "../<example_name>"` references that may reference the example by name.
5. `git init`, `git add .`, `git commit -m "Initial commit from libero/examples/<example_name>"`.
6. Print a "next steps" message: `cd <project_name> && bin/dev`.

Implementation: bash, ~30 lines. Uses curl, tar, find, sed, git. No external runtime deps.

User invocation:

```bash
# Basic — use the default example
curl -fsSL https://raw.githubusercontent.com/pairshaped/libero/main/bin/new | sh -s my_app

# Pick a different example
curl -fsSL https://raw.githubusercontent.com/pairshaped/libero/main/bin/new | sh -s my_todos todos
```

For users who don't want to run remote scripts:
- The README shows the `curl | sh` command and links to the script source on GitHub.
- The README also shows the script's body inline in a collapsed `<details>` block so users can read it without leaving the page.
- The script is small (~30 lines of bash) and easy to audit.

## Codegen and config changes

### Config defaults

In `src/libero/toml_config.gleam`:

| Field | Old default | New default |
|---|---|---|
| `server_src_dir` | `"src"` | `"src"` (unchanged — same package, just the package's location moved) |
| `server_generated_dir` | `"src/server/generated"` | `"src/generated"` |
| `server_atoms_path` | `"src/<name>@generated@rpc_atoms.erl"` | `"src/<name>@generated@rpc_atoms.erl"` (unchanged) |
| `shared_src_dir` | `"shared/src/shared"` | `"../shared/src/shared"` |
| `context_module` | `"server/handler_context"` | `"handler_context"` |

In `src/libero/config.gleam`:

| Field | Old default | New default |
|---|---|---|
| Atoms file path (no namespace) | `"src/server@generated@libero@rpc_atoms.erl"` | `"src/generated@libero@rpc_atoms.erl"` |
| Generated dispatch dir (no namespace) | `"src/server/generated/libero"` | `"src/generated/libero"` |

The `server/handler_context` → `handler_context` rename reflects that we're inside the server package; the redundant `server/` prefix goes away. Same for `server/generated` → `generated`.

### Codegen output paths

Currently `codegen.gleam` writes to `<server_generated>/dispatch.gleam`, `<server_generated>/websocket.gleam`, and per-client to `clients/<name>/src/generated/...`. With the new layout, libero's cwd is `server/`. The relative paths inside config become:
- Server outputs: `src/generated/dispatch.gleam`, `src/generated/websocket.gleam`
- Client outputs: `../clients/<name>/src/generated/...`

Codegen currently joins `server_generated` from cwd; that still works as long as the config value is correct. Verify during implementation that no path-resolution code assumes paths are non-relative.

### `[tools.libero.clients.X]` paths

Today: `path = "clients/<name>"`. New: `path = "../clients/<name>"`. The schema is identical, just defaults change.

## CLI collapse

Libero's CLI becomes single-purpose: invoking `gleam run -m libero` generates code. No subcommands, no flags. Same shape as marmot.

Files affected:

- **Delete:** `src/libero/cli.gleam` (argument parsing).
- **Delete:** `src/libero/cli/new.gleam` (replaced by `bin/new` shell script).
- **Delete:** `src/libero/cli/add.gleam` (manual edit instead).
- **Delete:** `src/libero/cli/templates.gleam` (replaced by `examples/` files).
- **Delete:** `src/libero/cli/parse_database.gleam` (no flags to parse).
- **Simplify:** `src/libero.gleam` becomes a thin entry: load config, run codegen, exit. No argv handling.

CLI surface becomes: `gleam run -m libero`. That's it.

Compilation stays where it lives in Gleam: `gleam build` per-package, `gleam run` to start the server. Libero is purely a code generator now, not a build orchestrator.

## Test coverage

Removed:
- `test/libero/cli_new_test.gleam` — `new` command deleted.
- `test/libero/cli_add_test.gleam` — `add` command deleted.
- `test/libero/cli_test.gleam` — argument parsing deleted.
- `test/libero/cli_parse_database_test.gleam` — flag parsing deleted.

Updated:
- `test/libero/codegen_config_test.gleam` — verify new path defaults.
- `test/libero/gen_run_test.gleam` — verify codegen runs against the new layout. May need fixture updates.

New:
- `test/libero/example_default_test.gleam` (or similar) — verify `examples/default/` builds successfully on both targets and that its server starts and serves a response. Treats the default example as a fixture.

## Migration story

**For libero itself:**
- The library source (`src/libero/`) doesn't move. Libero is a library, not a fullstack app.
- `examples/todos/` migrates to the three-peer layout. One-time mechanical change.
- Tests update for new paths.

**For curling/v3 (downstream):**
- Move `src/server/` → `server/src/`, drop the redundant `server/` prefix.
- Move root `gleam.toml`'s `[tools.libero]` into `server/gleam.toml`.
- Move `clients/admin/` → `clients/admin/` (no change to clients structure).
- Move `shared/` → `shared/` (no change).
- Update all imports: `server/handler_context` → `handler_context`, `server/foo` → `foo`, etc.
- Update `bin/dev`, `bin/build` paths.
- Run `gleam run -m libero` from new `server/` to regenerate, then `gleam build` and fix any breakage.

Pre-launch, this is a one-PR migration in v3. User-owned, separate from libero work.

**For new users:**
- Old getting-started: `gleam run -m libero -- new my_app --web`. No longer works.
- New getting-started: `curl -fsSL .../bin/new | sh -s my_app`, then `cd my_app && bin/dev`.

**For existing libero invocations:**
- Old: `gleam run -m libero -- gen` (or `-- build`, `-- add ...`).
- New: `gleam run -m libero` (just generates). Compilation/run is plain `gleam build` and `gleam run`. No subcommands.

## Risks

- **`bin/new` rename logic.** Replacing `default` (or whatever example name) with the user's project name across `gleam.toml` files is a sed replacement. If "default" appears in unexpected places (a comment, a string literal in starter code), it gets renamed too. Mitigation: the default example shouldn't have "default" in any non-config context. Audit the example contents before shipping.
- **Codegen path resolution.** Many places in `codegen.gleam` assume specific path shapes. Hidden assumptions about cwd or non-relative paths could surface during implementation. Mitigation: the existing `gen_run_test` fixture runs codegen against a real scaffold; it'll catch most of these.
- **`gleam.toml` path dep across packages.** `path = "../shared"` works in Gleam, but the build system needs to resolve symbolic vs absolute path quirks. Verify by running a fresh end-to-end build.
- **Examples drift.** With examples as templates, examples must build and run. If a libero change breaks an example, scaffolding breaks. Mitigation: CI builds and runs examples on every PR.
- **`bin/new` running on Windows.** The script is bash. Windows users need WSL or git-bash. Acceptable for a Gleam project (Gleam doesn't promise great Windows support either), but worth a sentence in the README.

## Open questions for the implementation plan

- **Example name vs project name in `gleam.toml`.** The default example's `gleam.toml` files name the package `default`. After rename, they name `my_app`. But what about the example in the libero repo when it's there? Maybe it stays as `default` and CI runs it as `default`. Then `bin/new` renames at copy time. Confirm during plan.
- **Modem dep version.** The default example uses modem. Pin version in spec? Today's example uses `modem ~> 2.1`. Confirm during plan.
- **Whether to keep a starter test in scaffold.** Old scaffold had `test/<name>_test.gleam` exercising `ping`. New layout puts it at `server/test/<name>_test.gleam`. Worth keeping. Confirm content is unchanged.
- **`.gitignore` content.** Each package has its own `build/`. Project root needs a `.gitignore` covering `*/build/`, `*/*/build/`, `.env`, etc.
- **README templates.** What does the scaffolded `README.md` say? Probably very thin: "this is my_app, run `bin/dev` to start." Confirm during plan.
- **CI for examples.** New responsibility: ensure examples build on every libero PR. New CI step or extension to existing.
