# Three-Peer Layout + Examples-as-Templates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reshape libero projects to Lustre's three-peer monorepo layout (`server/`, `shared/`, `clients/`), use `examples/` as scaffold templates, collapse the libero CLI to single-purpose generation, and ship a `bin/new` script for project bootstrapping.

**Architecture:** Sequential phases. Phase 1 collapses the CLI to leave only generation. Phase 2 updates path defaults in libero's config so codegen works inside a server-as-subdir layout. Phase 3 rewrites the gen_run integration test fixture for the new layout. Phase 4 builds `examples/default/` as the canonical minimal SSR-hydrated SPA. Phase 5 migrates `examples/todos/` to the new layout. Phase 6 ships the `bin/new` shell script. Phase 7 updates README and llms.txt.

**Tech Stack:** Gleam (Erlang + JS targets), lustre 5.6+, modem 2.1+, mist 6.0+, libero (the local library), bash for scripts. Tests use `gleeunit` and existing libero patterns.

**Spec:** `docs/superpowers/specs/2026-04-26-scaffold-default-hydration-design.md`

---

## Phase 1 — CLI collapse

Goal: invoking `gleam run -m libero` runs codegen, full stop. No subcommands, no arg parsing.

### Task 1.1: Baseline — confirm full test suite passes

**Files:**
- Read-only: all existing tests

- [ ] **Step 1: Run the test suite**

```sh
gleam test
```

Expected: all 270 tests pass. If they don't, stop and figure out why before proceeding.

- [ ] **Step 2: Confirm clean working tree**

```sh
git status
```

Expected: working tree clean (or only known-in-progress files). Phase 1 will produce one commit; clean tree at start helps verify.

### Task 1.2: Simplify `src/libero.gleam` to invoke codegen directly

**Files:**
- Modify: `src/libero.gleam`

- [ ] **Step 1: Replace `src/libero.gleam` content**

Current `src/libero.gleam` dispatches across `cli.New`, `cli.Add`, `cli.Gen`, `cli.Build`, `cli.Unknown`. Replace its full contents with:

```gleam
//// Libero — typed RPC framework for Gleam.
////
//// Usage: gleam run -m libero
////
//// Reads `gleam.toml` from the current directory and regenerates
//// dispatch, websocket, and client stubs based on handler signatures.

import gleam/io
import libero/cli/gen as cli_gen

pub fn main() -> Nil {
  let Nil = trap_signals()
  case cli_gen.run(project_path: ".") {
    Ok(Nil) -> Nil
    Error(msg) -> {
      io.println_error(msg)
      let _halt = halt(1)
      Nil
    }
  }
}

/// erlang:halt/1 never returns — it terminates the VM. The Nil return
/// type is a white lie required for type unification; code after
/// `let _halt = halt(1)` is dead but satisfies the type checker.
@external(erlang, "erlang", "halt")
fn halt(code: Int) -> Nil

@external(erlang, "libero_ffi", "trap_signals")
fn trap_signals() -> Nil
```

- [ ] **Step 2: Verify the file compiles**

```sh
gleam build
```

Expected: error. The deletion of cli.gleam, cli/new.gleam, etc. hasn't happened yet, but `libero.gleam` no longer imports them, so compile may succeed locally. If it still references cli imports they aren't here anymore — should compile clean.

If compile fails for other reasons, fix before proceeding.

### Task 1.3: Delete obsolete CLI subcommand files

**Files:**
- Delete: `src/libero/cli.gleam`
- Delete: `src/libero/cli/new.gleam`
- Delete: `src/libero/cli/add.gleam`
- Delete: `src/libero/cli/build.gleam`
- Delete: `src/libero/cli/templates.gleam`
- Delete: `src/libero/cli/templates/db.gleam`
- Delete: `src/libero/cli/helpers.gleam`
- Delete: `src/libero/cli/validation.gleam`

- [ ] **Step 1: Delete the files**

```sh
rm src/libero/cli.gleam
rm src/libero/cli/new.gleam
rm src/libero/cli/add.gleam
rm src/libero/cli/build.gleam
rm src/libero/cli/templates.gleam
rm src/libero/cli/templates/db.gleam
rmdir src/libero/cli/templates
rm src/libero/cli/helpers.gleam
rm src/libero/cli/validation.gleam
```

- [ ] **Step 2: Verify the project still compiles**

```sh
gleam build
```

Expected: success. Only `cli/gen.gleam` remains in `cli/`, and `libero.gleam` only imports that.

If compile fails:
- Run the failing module through `gleam build` and read the import error
- If something legitimately depends on a deleted module, restore it; otherwise update the dependent to remove the import

### Task 1.4: Delete obsolete CLI test files

**Files:**
- Delete: `test/libero/cli_new_test.gleam`
- Delete: `test/libero/cli_add_test.gleam`
- Delete: `test/libero/cli_test.gleam`
- Delete: `test/libero/cli_parse_database_test.gleam`

- [ ] **Step 1: Delete the test files**

```sh
rm test/libero/cli_new_test.gleam
rm test/libero/cli_add_test.gleam
rm test/libero/cli_test.gleam
rm test/libero/cli_parse_database_test.gleam
```

- [ ] **Step 2: Run the test suite**

```sh
gleam test
```

Expected: passes. Test count drops from 270 to roughly 230-250 (depending on tests-per-file in the deleted ones).

If any non-deleted tests fail, that means they referenced code we removed. Fix the failing test or the underlying issue before moving on.

### Task 1.5: Run lint and format

**Files:**
- All

- [ ] **Step 1: Run gleam format**

```sh
gleam format
```

Expected: clean (no changes). If files are reformatted, that's fine.

- [ ] **Step 2: Run glinter**

```sh
gleam run -m glinter
```

Expected: clean.

If any lints fire on `src/libero.gleam`, address them. If lints fire on other files, that's pre-existing — not for this phase.

### Task 1.6: Commit Phase 1

**Files:**
- All Phase 1 changes

- [ ] **Step 1: Stage and commit**

```sh
git add -A
git commit -m "Collapse libero CLI to single-purpose generation

Remove subcommand parsing (new, add, build) and the bespoke scaffold
templates. Invoking 'gleam run -m libero' now generates code, full stop.
Mirrors marmot's pattern. Project scaffolding moves to bin/new (separate
phase). Tests covering deleted subcommands removed."
```

- [ ] **Step 2: Verify**

```sh
git log --oneline -1
gleam test
```

Expected: commit lands, tests pass.

---

## Phase 2 — Update path defaults for new layout

Goal: change config defaults so libero's codegen, when run from a `server/` package inside the new layout, writes to the correct paths (relative to its cwd which is `server/`, not project root).

### Task 2.1: Update `src/libero/toml_config.gleam` defaults

**Files:**
- Modify: `src/libero/toml_config.gleam`

- [ ] **Step 1: Read the current defaults**

Open `src/libero/toml_config.gleam`. Locate the `parse` function. Find the lines that set defaults for `server_generated_dir`, `shared_src_dir`, `context_module`, `server_atoms_path`. They currently look like:

```gleam
let server_generated_dir =
  tom.get_string(parsed, ["tools", "libero", "server", "generated_dir"])
  |> result.unwrap("src/server/generated")

let shared_src_dir =
  tom.get_string(parsed, ["tools", "libero", "shared", "src_dir"])
  |> result.unwrap("shared/src/shared")

let context_module =
  tom.get_string(parsed, ["tools", "libero", "context_module"])
  |> result.unwrap("server/handler_context")
```

(Locations approximate; use grep if needed: `grep -n "server/generated\|shared/src/shared\|server/handler_context" src/libero/toml_config.gleam`.)

- [ ] **Step 2: Update the defaults**

Change to:

```gleam
let server_generated_dir =
  tom.get_string(parsed, ["tools", "libero", "server", "generated_dir"])
  |> result.unwrap("src/generated")

let shared_src_dir =
  tom.get_string(parsed, ["tools", "libero", "shared", "src_dir"])
  |> result.unwrap("../shared/src/shared")

let context_module =
  tom.get_string(parsed, ["tools", "libero", "context_module"])
  |> result.unwrap("handler_context")
```

The rationale: codegen runs from `server/`, so `src/generated` writes inside `server/src/generated`. `../shared/src/shared` reaches the sibling shared package. `handler_context` (no `server/` prefix) reflects that we're already inside the server package.

- [ ] **Step 3: Update inline doc comments to match**

In `src/libero/toml_config.gleam`, the doc comments next to these defaults reference the old paths. Update them. Find the `TomlConfig` record type and its inline doc:

```gleam
    /// Directory where libero writes server-side generated code
    /// (dispatch, websocket). Default: "src/server/generated".
    server_generated_dir: String,
```

Change `Default: "src/server/generated"` to `Default: "src/generated" (relative to server package root)`.

For `shared_src_dir`'s comment, update similarly: `Default: "../shared/src/shared" (relative to server package root)`.

For `context_module`: `Default: "handler_context"`.

### Task 2.2: Update `test/libero/toml_config_test.gleam` for new defaults

**Files:**
- Modify: `test/libero/toml_config_test.gleam`

This test pins the default values for `server_generated_dir`, `shared_src_dir`, `context_module`. After Task 2.1 it will fail; update assertions.

- [ ] **Step 1: Update `parse_uses_shared_plus_server_defaults_test`**

Find the test (lines 18-27 in current file). Update the assertions:

```gleam
pub fn parse_uses_shared_plus_server_defaults_test() {
  // No tools.libero overrides -> defaults assume three-peer layout (server/, shared/, clients/)
  // with libero running from the server package.
  let toml = "name = \"myapp\"\n"
  let assert Ok(cfg) = toml_config.parse(toml)
  let assert "src" = cfg.server_src_dir
  let assert "src/generated" = cfg.server_generated_dir
  let assert "../shared/src/shared" = cfg.shared_src_dir
  let assert "handler_context" = cfg.context_module
  let assert "src/myapp@generated@rpc_atoms.erl" = cfg.server_atoms_path
}
```

- [ ] **Step 2: Update `to_codegen_config_javascript_client_test`**

Find the test (lines 70-89). The fixture builds a `TomlConfig` record literal. Update its field values to reflect new defaults:

```gleam
pub fn to_codegen_config_javascript_client_test() {
  let toml_cfg =
    TomlConfig(
      name: "my_app",
      port: 3000,
      rest: False,
      clients: [ClientConfig(name: "web", target: "javascript")],
      server_src_dir: "src",
      server_generated_dir: "src/generated",
      server_atoms_path: "src/my_app@generated@rpc_atoms.erl",
      shared_src_dir: "../shared/src/shared",
      context_module: "handler_context",
    )
  let assert Ok(cfg) =
    toml_config.to_codegen_config(toml_cfg, client: "web", ws_path: "/ws")
  let assert "../clients/web/src/generated" = cfg.client_generated
  let assert "src/generated" = cfg.server_generated
  let assert Some("../shared/src/shared") = cfg.shared_src
  let assert WsPathOnly(path: "/ws") = cfg.ws_mode
}
```

Note: `cfg.client_generated` becomes `../clients/web/src/generated` because `to_codegen_config` derives the client output path from the new client config (`path = "../clients/web"`). If `to_codegen_config` doesn't yet support relative client paths (it might assume `clients/<name>` from project root), that's a behavior change to address now.

- [ ] **Step 3: Update `to_codegen_config_missing_client_test`**

Same field updates as Step 2 (it's the same fixture record):

```gleam
pub fn to_codegen_config_missing_client_test() {
  let toml_cfg =
    TomlConfig(
      name: "my_app",
      port: 3000,
      rest: False,
      clients: [],
      server_src_dir: "src",
      server_generated_dir: "src/generated",
      server_atoms_path: "src/my_app@generated@rpc_atoms.erl",
      shared_src_dir: "../shared/src/shared",
      context_module: "handler_context",
    )
  let assert Error(msg) =
    toml_config.to_codegen_config(toml_cfg, client: "web", ws_path: "/ws")
  let assert True = string.contains(msg, "Client not found")
  let assert True = string.contains(msg, "web")
}
```

- [ ] **Step 4: Run the toml config tests**

```sh
gleam test 2>&1 | grep -A1 "toml_config"
```

Expected: tests pass.

If `to_codegen_config_javascript_client_test` fails because `cfg.client_generated` returns the old `clients/web/...` path, that means `toml_config.to_codegen_config` builds the client output path from a hardcoded `"clients/<name>/src/generated"` template rather than reading the client's `path = "..."` config. Find that code in `src/libero/toml_config.gleam` (search for `client_generated` or `clients/`) and update it to read the per-client `path` field.

### Task 2.3: Update `src/libero/config.gleam` defaults

**Files:**
- Modify: `src/libero/config.gleam`

- [ ] **Step 1: Locate the path defaults**

In `src/libero/config.gleam`, find the namespace-aware path helpers. Around lines 90-95 and 130-135 you'll see paths like:

```gleam
"src/server@generated@libero@rpc_atoms.erl"
```

and:

```gleam
None -> "src/server/generated/libero"
Some(ns) -> "src/server/generated/libero/" <> ns
```

Confirm with: `grep -n "src/server" src/libero/config.gleam`.

- [ ] **Step 2: Update atoms file path**

Change `"src/server@generated@libero@rpc_atoms.erl"` to `"src/generated@libero@rpc_atoms.erl"`.

Change `"src/server@generated@libero@" <> ns <> "@rpc_atoms.erl"` to `"src/generated@libero@" <> ns <> "@rpc_atoms.erl"`.

- [ ] **Step 3: Update generated dispatch dir**

Change:

```gleam
None -> "src/server/generated/libero"
Some(ns) -> "src/server/generated/libero/" <> ns
```

to:

```gleam
None -> "src/generated/libero"
Some(ns) -> "src/generated/libero/" <> ns
```

### Task 2.4: Update other tests pinning old default paths

**Files:**
- Modify: `test/libero/config_test.gleam`
- Modify: `test/libero/config_prefix_test.gleam`
- Modify: `test/libero/module_path_test.gleam`
- Modify: `test/libero/endpoint_dispatch_test.gleam`

These tests pin specific path strings that change with the new defaults. Update them mechanically.

- [ ] **Step 1: Update `test/libero/config_test.gleam`**

Find any assertion like `"src/server@generated@libero@rpc_atoms.erl"` and update to `"src/generated@libero@rpc_atoms.erl"`.

```sh
grep -n "src/server@generated\|src/server/generated" test/libero/config_test.gleam
```

For each match, update the path: drop the `server/` segment.

- [ ] **Step 2: Update `test/libero/config_prefix_test.gleam`**

Similar treatment. Search:

```sh
grep -n "src/server/generated\|shared/src/shared" test/libero/config_prefix_test.gleam
```

For `server_generated` paths: `src/server/generated` → `src/generated`. For `shared_src` paths in fixture inputs: keep as `shared/src/shared` if the test simulates a project with the OLD layout (no relative parent), OR update to `../shared/src/shared` if the test fixture should reflect new defaults. Read each test to decide; the comment in `parse_uses_shared_plus_server_defaults_test` (now updated in 2.2) is your guide.

- [ ] **Step 3: Update `test/libero/module_path_test.gleam`**

Search:

```sh
grep -n "src/server/generated" test/libero/module_path_test.gleam
```

Update assertions like `"src/server/generated/libero"` → `"src/generated/libero"` and corresponding input strings in `extract_dir` calls.

- [ ] **Step 4: Update `test/libero/endpoint_dispatch_test.gleam`**

Several fixture record literals set `context_module: "server/handler_context"`. Update each to `context_module: "handler_context"`.

```sh
grep -n "server/handler_context" test/libero/endpoint_dispatch_test.gleam
```

Also find the template string at line ~296 (`"import server/handler_context.{type HandlerContext}\n..."`). Update to `"import handler_context.{type HandlerContext}\n..."`.

### Task 2.5: Run library tests

**Files:**
- Read-only

- [ ] **Step 1: Run tests**

```sh
gleam test
```

Expected: `gen_run_test` tests still fail (we fix those in Phase 3). All others should pass.

If a non-gen_run test fails, the failure points at code that pins old paths. The most likely sources:
- A test fixture string that was missed in Tasks 2.2-2.4. Use grep to find it.
- A non-test code path that builds a path string by template (e.g., `"src/server/generated/" <> ...` somewhere in `src/libero/`). Search and fix.
- The wire e2e fixture `test/fixtures/wire_e2e/`. Its `gleam.toml` doesn't set `[tools.libero]` path overrides, so it'll inherit the new defaults but its file structure is the old layout. If `wire_e2e` tests fail, add explicit overrides to `test/fixtures/wire_e2e/gleam.toml`:

```toml
[tools.libero]
port = 8080
server.generated_dir = "src/server/generated"
shared.src_dir = "shared/src/shared"
context_module = "server/handler_context"
```

This keeps the fixture using the old paths without restructuring it.

- [ ] **Step 2: Stage and commit Phase 2**

```sh
git add -A
git commit -m "Update libero config defaults for three-peer layout

Codegen runs from server/ now, so paths default relative to that
package root: src/generated for codegen output, ../shared/src/shared
for shared types, handler_context (no server/ prefix) for context
module. Updated tests that pinned the old defaults. gen_run_test
fixtures fixed separately in Phase 3."
```

---

## Phase 3 — Rewrite `gen_run_test` fixture for new layout

Goal: the integration test for codegen needs to construct a three-peer layout fixture and invoke `gen.run` from the server's path. Each test asserts files land in the right place inside the server package (and inside sibling clients/).

### Task 3.1: Read the existing fixture

**Files:**
- Read: `test/libero/gen_run_test.gleam`

- [ ] **Step 1: Open and skim the test**

```sh
cat test/libero/gen_run_test.gleam | head -200
```

Familiarize yourself with `setup_endpoint_fixture`, `endpoint_gleam_toml`, and the four tests:
- `gen_run_writes_dispatch_inside_project_path_test`
- `gen_run_writes_atoms_inside_project_path_test`
- `gen_run_writes_main_inside_project_path_test`
- `gen_run_writes_client_stubs_inside_project_path_test`

Each asserts a generated file lands inside the project_path (not leaking to libero's own src/).

### Task 3.2: Rewrite `setup_endpoint_fixture` for three-peer layout

**Files:**
- Modify: `test/libero/gen_run_test.gleam`

- [ ] **Step 1: Replace the fixture function**

Find `fn setup_endpoint_fixture(path: String) -> Nil` and replace with:

```gleam
// -- fixture --
//
// Builds a three-peer monorepo at `path`:
//   <path>/server/   - server package (where libero runs from)
//   <path>/shared/   - cross-target shared types
//   <path>/clients/web/ - JS client
//
// gen.run is called with project_path = <path>/server.

fn setup_endpoint_fixture(path: String) -> Nil {
  let app_name = derive_app_name(path)

  // Create directories
  let assert Ok(Nil) =
    simplifile.create_directory_all(path <> "/shared/src/shared")
  let assert Ok(Nil) = simplifile.create_directory_all(path <> "/server/src")
  let assert Ok(Nil) =
    simplifile.create_directory_all(path <> "/clients/web/src")

  // Server gleam.toml with [tools.libero] config
  write_file(path <> "/server/gleam.toml", endpoint_gleam_toml(app_name))

  // Shared types module — defines the domain type used in handler signatures
  write_file(
    path <> "/shared/src/shared/types.gleam",
    "pub type Item {
  Item(id: Int, name: String)
}
",
  )

  // Server entry — required for codegen's main.gleam discovery
  write_file(
    path <> "/server/src/" <> app_name <> ".gleam",
    "pub fn main() {
  Nil
}
",
  )

  // Server handler context
  write_file(
    path <> "/server/src/handler_context.gleam",
    "pub type HandlerContext {
  HandlerContext
}
",
  )

  // Server handler — the endpoint codegen scans for
  write_file(
    path <> "/server/src/handler.gleam",
    "import handler_context.{type HandlerContext}
import shared/types.{type Item}

pub fn list_items(state state: HandlerContext) -> #(Result(List(Item), Nil), HandlerContext) {
  #(Ok([]), state)
}
",
  )
}
```

(`derive_app_name` and `write_file` likely already exist below; do not rewrite them.)

- [ ] **Step 2: Update `endpoint_gleam_toml` if needed**

Find `fn endpoint_gleam_toml(app_name: String) -> String` further down. It currently outputs a `gleam.toml` for the old root-as-server layout. Update so it produces a server-package gleam.toml with the right structure. Replace its body with:

```gleam
fn endpoint_gleam_toml(app_name: String) -> String {
  "name = \"" <> app_name <> "\"
version = \"0.1.0\"
target = \"erlang\"

[dependencies]
gleam_stdlib = \">= 0.69.0 and < 1.0.0\"
shared = { path = \"../shared\" }

[tools.libero]
port = 8080

[tools.libero.clients.web]
target = \"javascript\"
path = \"../clients/web\"
"
}
```

### Task 3.3: Update test paths to assert against the new layout

**Files:**
- Modify: `test/libero/gen_run_test.gleam`

- [ ] **Step 1: Update `gen_run_writes_dispatch_inside_project_path_test`**

Replace its body:

```gleam
pub fn gen_run_writes_dispatch_inside_project_path_test() {
  let path = "build/.test_gen_run_endpoint"
  setup_endpoint_fixture(path)

  let assert Ok(Nil) = gen.run(project_path: path <> "/server")

  // Endpoint dispatch landed inside the server package.
  let assert Ok(dispatch) =
    simplifile.read(path <> "/server/src/generated/dispatch.gleam")
  let assert True = string.contains(dispatch, "pub type ClientMsg")

  // No leak into libero's own src tree.
  let assert Error(_) = simplifile.read("src/generated/dispatch.gleam")

  let assert Ok(Nil) = simplifile.delete_all([path])
}
```

- [ ] **Step 2: Update `gen_run_writes_atoms_inside_project_path_test`**

```gleam
pub fn gen_run_writes_atoms_inside_project_path_test() {
  let path = "build/.test_gen_run_atoms"
  setup_endpoint_fixture(path)

  let assert Ok(Nil) = gen.run(project_path: path <> "/server")

  let assert Ok(_) =
    simplifile.read(path <> "/server/src/test_atoms@generated@rpc_atoms.erl")
  let assert Error(_) =
    simplifile.read("src/test_atoms@generated@rpc_atoms.erl")

  let assert Ok(Nil) = simplifile.delete_all([path])
}
```

- [ ] **Step 3: Update `gen_run_writes_main_inside_project_path_test`**

The "main" test checks that codegen creates the server entry. Since `setup_endpoint_fixture` now pre-writes a server entry, the test should verify codegen kept-or-replaced the file. Look at codegen's main.gleam handling — it uses `write_if_missing`. So if our fixture wrote it, codegen leaves it alone. Adjust the assertion accordingly:

```gleam
pub fn gen_run_writes_main_inside_project_path_test() {
  let path = "build/.test_gen_run_main"
  setup_endpoint_fixture(path)

  let assert Ok(Nil) = gen.run(project_path: path <> "/server")

  // Server entry exists (write_if_missing preserved our fixture's version).
  let assert Ok(_) = simplifile.read(path <> "/server/src/test_main.gleam")
  let assert Error(_) = simplifile.read("src/test_main.gleam")

  let assert Ok(Nil) = simplifile.delete_all([path])
}
```

- [ ] **Step 4: Update `gen_run_writes_client_stubs_inside_project_path_test`**

```gleam
pub fn gen_run_writes_client_stubs_inside_project_path_test() {
  let path = "build/.test_gen_run_client"
  setup_endpoint_fixture(path)

  let assert Ok(Nil) = gen.run(project_path: path <> "/server")

  // Client stubs landed in the sibling clients/web/ package.
  let assert Ok(_) =
    simplifile.read(path <> "/clients/web/src/generated/messages.gleam")
  let assert Error(_) =
    simplifile.read("clients/web/src/generated/messages.gleam")

  let assert Ok(Nil) = simplifile.delete_all([path])
}
```

### Task 3.4: Run gen_run_test

**Files:**
- Read-only

- [ ] **Step 1: Run just the gen_run tests**

```sh
gleam test 2>&1 | grep -A1 "gen_run"
```

Expected: all four `gen_run_*` tests pass.

If they fail, the most likely causes:
- Path-resolution code in `cli/gen.gleam` or `codegen.gleam` makes assumptions that break with relative paths like `../shared`. Fix by ensuring path joins handle relative segments correctly.
- The `[tools.libero.clients.web]` config section has `path = "../clients/web"` and codegen tries to read it as if it were under `server/`. Verify `gen.run` resolves the client path relative to its own cwd or to `project_path`.

Read the failure carefully and fix the underlying issue. Don't paper over by hardcoding paths in tests.

- [ ] **Step 2: Run the full test suite**

```sh
gleam test
```

Expected: all tests pass.

- [ ] **Step 3: Commit Phase 3**

```sh
git add test/libero/gen_run_test.gleam
git commit -m "Rewrite gen_run_test fixture for three-peer layout

Fixture now constructs server/, shared/, clients/web/ as siblings.
gen.run is invoked with project_path pointing at the server/ subdir.
Assertions check generated files land inside the server package and
inside sibling clients/, with no leak into libero's own src tree."
```

---

## Phase 4 — Build `examples/default/`

Goal: a minimal SSR-hydrated SPA that compiles, runs, server-renders, and hydrates. Doubles as the canonical scaffold output.

### Task 4.1: Create directory structure

**Files:**
- Create: `examples/default/` and subdirs

- [ ] **Step 1: Create the directory tree**

```sh
mkdir -p examples/default/server/src
mkdir -p examples/default/shared/src/shared
mkdir -p examples/default/clients/web/src
mkdir -p examples/default/bin
```

### Task 4.2: Create `shared/` package files

**Files:**
- Create: `examples/default/shared/gleam.toml`
- Create: `examples/default/shared/src/shared/router.gleam`
- Create: `examples/default/shared/src/shared/types.gleam`
- Create: `examples/default/shared/src/shared/views.gleam`

- [ ] **Step 1: Write `shared/gleam.toml`**

```toml
name = "shared"
version = "0.1.0"

# No target specified — compiles to both Erlang and JavaScript.

[dependencies]
gleam_stdlib = ">= 0.69.0 and < 1.0.0"
gleam_uri = ">= 1.0.0 and < 2.0.0"
lustre = "~> 5.6"
libero = { path = "../../.." }

[dev-dependencies]
gleeunit = "~> 1.0"
```

(`libero = { path = "../../.." }` because `examples/default/shared/` is three levels deep from libero's repo root. Adjust if libero's relative depth changes.)

- [ ] **Step 2: Write `shared/src/shared/router.gleam`**

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

- [ ] **Step 3: Write `shared/src/shared/types.gleam`**

```gleam
pub type PingError {
  PingFailed
}
```

- [ ] **Step 4: Write `shared/src/shared/views.gleam`**

```gleam
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

- [ ] **Step 5: Build the shared package**

```sh
cd examples/default/shared && gleam build && cd -
```

Expected: success on both Erlang and JavaScript implicitly (no `target` set means Gleam tries both as needed).

If it fails, fix imports and types before continuing.

### Task 4.3: Create `server/` package files

**Files:**
- Create: `examples/default/server/gleam.toml`
- Create: `examples/default/server/src/default.gleam`
- Create: `examples/default/server/src/handler.gleam`
- Create: `examples/default/server/src/handler_context.gleam`
- Create: `examples/default/server/src/page.gleam`

- [ ] **Step 1: Write `server/gleam.toml`**

```toml
name = "default"
version = "0.1.0"
target = "erlang"

[dependencies]
gleam_stdlib = ">= 0.69.0 and < 1.0.0"
gleam_erlang = "~> 1.0"
gleam_http = "~> 4.0"
mist = "~> 6.0"
lustre = "~> 5.6"
shared = { path = "../shared" }
libero = { path = "../../../.." }

[dev-dependencies]
gleeunit = "~> 1.0"

[tools.libero]
port = 8080

[tools.libero.clients.web]
target = "javascript"
path = "../clients/web"
```

- [ ] **Step 2: Write `server/src/handler_context.gleam`**

```gleam
pub type HandlerContext {
  HandlerContext
}

pub fn new() -> HandlerContext {
  HandlerContext
}
```

- [ ] **Step 3: Write `server/src/handler.gleam`**

```gleam
import handler_context.{type HandlerContext}
import shared/types.{type PingError}

pub fn ping(
  state state: HandlerContext,
) -> #(Result(String, PingError), HandlerContext) {
  #(Ok("pong"), state)
}
```

- [ ] **Step 4: Write `server/src/page.gleam`**

```gleam
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
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
) -> Result(Model, Response(ResponseData)) {
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

- [ ] **Step 5: Write `server/src/default.gleam` (server entry)**

This is the manual server entry. Codegen would emit this, but for the example we write it by hand as the canonical shape:

```gleam
//// Server entry point.

import gleam/bytes_tree
import gleam/erlang/process
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response
import gleam/option.{None, Some}
import gleam/string
import generated/dispatch
import generated/websocket as ws
import handler_context
import libero/push
import libero/ssr
import libero/ws_logger
import mist.{type Connection}
import page
import shared/router
import simplifile

pub fn main() {
  let _ = push.init()
  let _ = dispatch.ensure_atoms()
  let state = handler_context.new()
  let logger = ws_logger.default_logger()

  let assert Ok(_) =
    fn(req: Request(Connection)) {
      case req.method, request.path_segments(req) {
        _, ["ws"] -> ws.upgrade(request: req, state:, topics: [], logger:)
        http.Post, ["rpc"] -> handle_rpc(req, state, logger)
        _, ["web", ..path] ->
          serve_file(
            "../clients/web/build/dev/javascript/" <> string.join(path, "/"),
          )
        _, _ ->
          ssr.handle_request(
            req:,
            parse: router.parse_route,
            load: page.load_page,
            render: page.render_page,
            state:,
          )
      }
    }
    |> mist.new
    |> mist.port(8080)
    |> mist.start

  process.sleep_forever()
}

fn handle_rpc(
  req: Request(Connection),
  state: handler_context.HandlerContext,
  logger: ws_logger.Logger,
) -> response.Response(mist.ResponseData) {
  case mist.read_body(req, 1_000_000) {
    Ok(req) -> {
      let #(response_bytes, maybe_panic, _new_state) =
        dispatch.handle(state:, data: req.body)
      case maybe_panic {
        Some(info) ->
          logger.error(
            "RPC panic: "
            <> info.fn_name
            <> " (trace "
            <> info.trace_id
            <> "): "
            <> info.reason,
          )
        None -> Nil
      }
      response.new(200)
      |> response.set_body(mist.Bytes(bytes_tree.from_bit_array(response_bytes)))
    }
    Error(_) ->
      response.new(400)
      |> response.set_body(mist.Bytes(bytes_tree.from_string("Bad request")))
  }
}

fn serve_file(path: String) -> response.Response(mist.ResponseData) {
  case simplifile.read_bits(path) {
    Ok(bytes) ->
      response.new(200)
      |> response.set_header("content-type", content_type_for(path))
      |> response.set_body(mist.Bytes(bytes_tree.from_bit_array(bytes)))
    Error(_) ->
      response.new(404)
      |> response.set_body(mist.Bytes(bytes_tree.from_string("Not found")))
  }
}

fn content_type_for(path: String) -> String {
  case string.ends_with(path, ".mjs") || string.ends_with(path, ".js") {
    True -> "application/javascript"
    False ->
      case string.ends_with(path, ".css") {
        True -> "text/css"
        False -> "application/octet-stream"
      }
  }
}
```

- [ ] **Step 6: Run libero codegen for the server**

```sh
cd examples/default/server && gleam run -m libero && cd -
```

Expected: codegen runs successfully, writes `src/generated/dispatch.gleam`, `src/generated/websocket.gleam`, atoms file, and `../clients/web/src/generated/...` files (those will fail to write if `clients/web` doesn't exist yet — that's fine, we create it next).

If codegen errors with "client path does not exist," skip ahead to Task 4.4 and run codegen again at the end of that task.

### Task 4.4: Create `clients/web/` package files

**Files:**
- Create: `examples/default/clients/web/gleam.toml`
- Create: `examples/default/clients/web/src/app.gleam`
- Create: `examples/default/clients/web/src/flags_ffi.mjs`

- [ ] **Step 1: Write `clients/web/gleam.toml`**

```toml
name = "web"
version = "0.1.0"
target = "javascript"

[dependencies]
gleam_stdlib = ">= 0.69.0 and < 1.0.0"
shared = { path = "../../shared" }
lustre = "~> 5.6"
modem = "~> 2.1"
libero = { path = "../../../../.." }

[dev-dependencies]
gleeunit = "~> 1.0"
```

- [ ] **Step 2: Write `clients/web/src/flags_ffi.mjs`**

```js
export function getFlags() {
  return globalThis.window?.__LIBERO_FLAGS__ ?? null;
}
```

- [ ] **Step 3: Write `clients/web/src/app.gleam`**

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
import shared/views.{
  type Model, type Msg, Model, NavigateTo, NoOp, UserClickedPing,
}

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

- [ ] **Step 4: Run libero codegen so client stubs land**

```sh
cd examples/default/server && gleam run -m libero && cd -
```

Expected: success. Now `examples/default/clients/web/src/generated/messages.gleam` and other client stubs exist.

- [ ] **Step 5: Build the client**

```sh
cd examples/default/clients/web && gleam build --target javascript && cd -
```

Expected: success. If imports or types are wrong, fix and re-run.

### Task 4.5: Build the server

**Files:**
- Read-only

- [ ] **Step 1: Build the server**

```sh
cd examples/default/server && gleam build && cd -
```

Expected: success. The server compiles against shared (Erlang) and libero (Erlang).

### Task 4.6: Add `bin/` scripts

**Files:**
- Create: `examples/default/bin/dev`
- Create: `examples/default/bin/test`

- [ ] **Step 1: Write `bin/dev`**

```bash
#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Regenerate libero codegen before running.
cd "$DIR/server"
gleam run -m libero

# Build the JS client so /web/web/app.mjs is available.
cd "$DIR/clients/web"
gleam build --target javascript

# Start the server.
cd "$DIR/server"
gleam run
```

- [ ] **Step 2: Write `bin/test`**

```bash
#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$DIR/server" && gleam test
```

- [ ] **Step 3: Make scripts executable**

```sh
chmod +x examples/default/bin/dev examples/default/bin/test
```

### Task 4.7: Add starter test

**Files:**
- Create: `examples/default/server/test/default_test.gleam`

- [ ] **Step 1: Create test directory and file**

```sh
mkdir -p examples/default/server/test
```

Write `examples/default/server/test/default_test.gleam`:

```gleam
import gleeunit
import handler
import handler_context

pub fn main() {
  gleeunit.main()
}

pub fn ping_test() {
  let state = handler_context.new()
  let assert #(Ok("pong"), _) = handler.ping(state:)
}
```

- [ ] **Step 2: Run the test**

```sh
cd examples/default/server && gleam test && cd -
```

Expected: 1 test passes.

### Task 4.8: Add README and .gitignore

**Files:**
- Create: `examples/default/README.md`
- Create: `examples/default/.gitignore`

- [ ] **Step 1: Write `examples/default/README.md`**

```markdown
# default

Minimal libero starter: SSR-hydrated SPA with one route, one handler, and one button.

## Run

```sh
bin/dev
```

Open http://localhost:8080. The page renders server-side, hydrates on the client, and the Ping button calls the `ping` handler over RPC.

## Tests

```sh
bin/test
```

## Layout

```
default/
├── server/         backend (Erlang), runs the libero RPC + SSR server
├── shared/         cross-target types, views, and routing
├── clients/web/    Lustre SPA (JavaScript)
└── bin/            dev and test entry points
```

## Adding a route

Edit `shared/src/shared/router.gleam` to add a `Route` variant and update `parse_route` and `route_to_path`. Then update `shared/src/shared/views.gleam` to handle the new variant in `view`. The server picks it up via `ssr.handle_request` automatically.

## Adding a handler

Add a function in `server/src/handler.gleam`. It must:
- Be `pub`
- Take `HandlerContext` as its last parameter (named `state`)
- Return `#(Result(value, error), HandlerContext)`
- Use only types from `shared/` or builtins

Then run `bin/dev` (or `cd server && gleam run -m libero`) to regenerate dispatch + client stubs.

## Adding a client

Create `clients/<name>/` with a gleam.toml that declares the right target and lists shared + libero as deps. Add a `[tools.libero.clients.<name>]` block to `server/gleam.toml`.
```

- [ ] **Step 2: Write `examples/default/.gitignore`**

```
*/build/
*/*/build/
.env
*.beam
erl_crash.dump
```

### Task 4.9: Verify end-to-end build

**Files:**
- Read-only

- [ ] **Step 1: Run full build pipeline**

```sh
cd examples/default
bin/test
cd ../..
```

Expected: tests pass.

- [ ] **Step 2: Smoke test the server (manual)**

```sh
cd examples/default
bin/dev &
DEV_PID=$!
sleep 5
curl -sS http://localhost:8080/ | head -20
kill $DEV_PID
cd ../..
```

Expected: HTML output containing `<h1>Hello from default</h1>` and `<script>` tags for the boot script.

If the server doesn't respond, check `bin/dev` output for build errors.

### Task 4.10: Commit Phase 4

**Files:**
- All Phase 4 changes

- [ ] **Step 1: Stage and commit**

```sh
git add examples/default
git commit -m "Add examples/default — minimal SSR-hydrated SPA scaffold

Three-peer monorepo: server/, shared/, clients/web/. Single Home route,
single ping handler, hydration via libero/ssr.boot_script + decode_flags.
Doubles as the canonical scaffold output: bin/new copies this directory."
```

---

## Phase 5 — Migrate `examples/todos/` to three-peer layout

Goal: bring the existing todos example to the new layout so it remains a working example after the layout reshape.

### Task 5.1: Move server source into `server/` subdir

**Current `examples/todos/` structure:**

```
examples/todos/
├── gleam.toml
├── manifest.toml
├── src/
│   ├── todos.gleam                  # server entry
│   ├── todos@generated@rpc_atoms.erl
│   └── server/
│       ├── handler.gleam
│       ├── handler_context.gleam
│       └── generated/               # codegen output
├── test/todos_test.gleam
├── shared/                          # stays in place
└── clients/                         # stays in place
```

**Target structure after this task:**

```
examples/todos/
├── server/
│   ├── gleam.toml
│   ├── manifest.toml
│   ├── src/
│   │   ├── todos.gleam
│   │   ├── todos@generated@rpc_atoms.erl
│   │   ├── handler.gleam
│   │   ├── handler_context.gleam
│   │   └── generated/
│   └── test/todos_test.gleam
├── shared/
└── clients/
```

**Files:**
- Move: 8 files under `examples/todos/`

- [ ] **Step 1: Move package files into a new `server/` subdir**

```sh
cd examples/todos
mkdir -p server/src server/test
git mv gleam.toml server/gleam.toml
git mv manifest.toml server/manifest.toml
git mv src/todos.gleam server/src/todos.gleam
git mv src/todos@generated@rpc_atoms.erl server/src/todos@generated@rpc_atoms.erl
git mv src/server/handler.gleam server/src/handler.gleam
git mv src/server/handler_context.gleam server/src/handler_context.gleam
git mv src/server/generated server/src/generated
git mv test/todos_test.gleam server/test/todos_test.gleam
rmdir src/server src test
cd ../..
```

- [ ] **Step 2: Verify the move**

```sh
ls examples/todos/
ls examples/todos/server/
ls examples/todos/server/src/
```

Expected:
- Top-level: `server`, `shared`, `clients`, `README.md` (and possibly `build/` from prior compiles)
- `server/`: `gleam.toml`, `manifest.toml`, `src/`, `test/`
- `server/src/`: `todos.gleam`, `todos@generated@rpc_atoms.erl`, `handler.gleam`, `handler_context.gleam`, `generated/`

### Task 5.2: Update server `gleam.toml` and config

**Files:**
- Modify: `examples/todos/server/gleam.toml`

- [ ] **Step 1: Update path deps to new relative locations**

The server's `gleam.toml` previously had `shared = { path = "shared" }`. Update to:

```
shared = { path = "../shared" }
libero = { path = "../../.." }
```

(Old libero path was likely `path = "../../"`. Adjust to reflect the new depth: `examples/todos/server/` is three dirs from libero repo root, so `../../../`.)

- [ ] **Step 2: Update `[tools.libero.clients.web]` path**

Find the `[tools.libero.clients.web]` block. Update its path to `../clients/web` (was `clients/web` in old layout).

- [ ] **Step 3: Verify no leftover stale config**

Search for any remaining old paths:

```sh
grep -n "src/server\|shared/src/shared" examples/todos/server/gleam.toml
```

Expected: nothing matches paths we don't want. Old paths should all be `../shared/src/shared` style now (or absent — defaults handle them).

### Task 5.3: Update imports in `server/src/`

**Files:**
- Modify: all `.gleam` files under `examples/todos/server/src/`

- [ ] **Step 1: Find imports that use the old `server/` prefix**

```sh
grep -rn "import server/" examples/todos/server/src/
```

Each match is an import like `import server/handler_context.{...}`. With the new layout, the server is the package root, so `server/` prefix goes away.

- [ ] **Step 2: Strip the `server/` prefix**

For each match, change `import server/<module>` to `import <module>`.

Be precise: do NOT change `import server/generated/dispatch` — wait, that one is server-package-internal. Let me think again.

Actually all `server/<x>` imports should become `<x>`. So `import server/generated/dispatch` becomes `import generated/dispatch`. The `server/` prefix is the legacy nesting; without it, the codegen output sits at `src/generated/dispatch.gleam` and is imported as `generated/dispatch`.

Use `sed` cautiously:

```sh
find examples/todos/server/src -name '*.gleam' -exec \
  sed -i.bak 's|^import server/|import |g' {} \;
find examples/todos/server/src -name '*.bak' -delete
```

- [ ] **Step 3: Verify no `import server/` remains**

```sh
grep -rn "import server/" examples/todos/server/src/
```

Expected: no matches.

### Task 5.4: Run codegen and build the server

**Files:**
- Read-only

- [ ] **Step 1: Run libero codegen**

```sh
cd examples/todos/server && gleam run -m libero && cd ../../..
```

Expected: codegen runs, writes `examples/todos/server/src/generated/dispatch.gleam`, atoms file, etc. May fail if `clients/web/` isn't migrated yet (Task 5.5).

If it complains about missing client files, that's OK — the client move is next.

- [ ] **Step 2: Build the server**

```sh
cd examples/todos/server && gleam build && cd ../../..
```

Expected: success.

If build fails with import errors, look for any file under `server/src/` that still references the old paths (e.g., `shared/src/shared/foo` or `server/foo`).

### Task 5.5: Migrate `clients/web/` paths

**Files:**
- Modify: `examples/todos/clients/web/gleam.toml`

- [ ] **Step 1: Update path deps**

The client's `gleam.toml` previously had `shared = { path = "../../shared" }` (two dirs up: clients/web → root → shared). With new layout it stays `shared = { path = "../../shared" }` because clients/web/ → clients/ → todos/ → shared/ (sibling). Adjust if the actual depth differs.

Also update libero: `libero = { path = "../../../../" }` → adjust depth to libero repo root from `clients/web/`. From `examples/todos/clients/web/` that's four dirs up: `../../../../`.

- [ ] **Step 2: Build the client**

```sh
cd examples/todos/clients/web && gleam build --target javascript && cd ../../../..
```

Expected: success.

### Task 5.6: Update `examples/todos/shared/gleam.toml` paths

**Files:**
- Modify: `examples/todos/shared/gleam.toml`

- [ ] **Step 1: Update libero path**

The shared package's `gleam.toml` may have `libero = { path = "../" }` from the old layout. Update to `libero = { path = "../../../" }` (three dirs up to libero repo root from `examples/todos/shared/`).

- [ ] **Step 2: Build shared**

```sh
cd examples/todos/shared && gleam build && cd ../../..
```

Expected: success.

### Task 5.7: Add `bin/` scripts to todos

**Files:**
- Create: `examples/todos/bin/dev`
- Create: `examples/todos/bin/test`

- [ ] **Step 1: Write the scripts (same as default)**

```sh
mkdir -p examples/todos/bin
cp examples/default/bin/dev examples/todos/bin/dev
cp examples/default/bin/test examples/todos/bin/test
```

These work identically — they don't reference the project name.

### Task 5.8: Verify end-to-end build

**Files:**
- Read-only

- [ ] **Step 1: Run tests**

```sh
cd examples/todos && bin/test && cd ../..
```

Expected: tests pass. If tests reference paths or modules with old prefixes, fix.

- [ ] **Step 2: Smoke test**

```sh
cd examples/todos
bin/dev &
DEV_PID=$!
sleep 5
curl -sS http://localhost:8080/ | head -10
kill $DEV_PID
cd ../..
```

Expected: HTML response. The exact content depends on what the todos example renders.

If the server fails to start, check `bin/dev` output.

### Task 5.9: Commit Phase 5

**Files:**
- All Phase 5 changes

- [ ] **Step 1: Stage and commit**

```sh
git add examples/todos
git commit -m "Migrate examples/todos to three-peer layout

Server moves from examples/todos/src/ to examples/todos/server/src/.
Imports drop the redundant server/ prefix. Path deps updated to
reflect the new relative depths. bin/dev and bin/test added."
```

---

## Phase 6 — `bin/new` script in libero repo

Goal: a `curl | sh`-style script that downloads the libero tarball, extracts an example, renames, and inits git.

### Task 6.1: Write `bin/new`

**Files:**
- Create: `bin/new` (in libero repo root)

- [ ] **Step 1: Create the script**

```sh
mkdir -p bin
```

Write `bin/new`:

```bash
#!/usr/bin/env bash
set -euo pipefail

NAME="${1:-}"
TEMPLATE="${2:-default}"

if [ -z "$NAME" ]; then
  echo "usage: curl -fsSL https://raw.githubusercontent.com/pairshaped/libero/main/bin/new | sh -s <project_name> [template]"
  echo ""
  echo "Examples:"
  echo "  ... | sh -s my_app           # uses examples/default"
  echo "  ... | sh -s my_todos todos   # uses examples/todos"
  exit 1
fi

if [ -e "$NAME" ]; then
  echo "error: $NAME already exists"
  exit 1
fi

TARBALL="https://github.com/pairshaped/libero/archive/main.tar.gz"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

echo "Downloading libero/examples/$TEMPLATE ..."
curl -fsSL "$TARBALL" | tar xz -C "$TMPDIR"

SRC="$TMPDIR/libero-main/examples/$TEMPLATE"
if [ ! -d "$SRC" ]; then
  echo "error: examples/$TEMPLATE not found in libero"
  exit 1
fi

cp -r "$SRC" "$NAME"

echo "Renaming $TEMPLATE → $NAME in gleam.toml files ..."
find "$NAME" -name 'gleam.toml' -exec \
  sed -i.bak "s/name = \"$TEMPLATE\"/name = \"$NAME\"/g" {} \;
find "$NAME" -name '*.bak' -delete

# Rename the server entry file: server/src/<template>.gleam → server/src/<name>.gleam
if [ -f "$NAME/server/src/$TEMPLATE.gleam" ]; then
  mv "$NAME/server/src/$TEMPLATE.gleam" "$NAME/server/src/$NAME.gleam"
fi

# Rename the test: server/test/<template>_test.gleam → server/test/<name>_test.gleam
if [ -f "$NAME/server/test/${TEMPLATE}_test.gleam" ]; then
  mv "$NAME/server/test/${TEMPLATE}_test.gleam" "$NAME/server/test/${NAME}_test.gleam"
fi

# Drop libero path-dep, replace with hex dep
# (the example uses a path dep so it builds inside the libero repo;
# scaffolded apps get libero from hex)
find "$NAME" -name 'gleam.toml' -exec \
  sed -i.bak 's|libero = { path = "[^"]*" }|libero = "~> 5.0"|g' {} \;
find "$NAME" -name '*.bak' -delete

cd "$NAME"
git init -q
git add .
git commit -q -m "Initial commit from libero/examples/$TEMPLATE"

echo ""
echo "Created $NAME from libero/examples/$TEMPLATE"
echo ""
echo "Next steps:"
echo "  cd $NAME"
echo "  bin/dev"
```

- [ ] **Step 2: Make it executable**

```sh
chmod +x bin/new
```

### Task 6.2: Test `bin/new` locally

**Files:**
- Read-only

- [ ] **Step 1: Test against a local copy**

The script downloads from GitHub. To test locally without network, we can simulate by copying the example directly:

```sh
# Test the rename logic by running a manual copy
TESTDIR="$(mktemp -d)"
cd "$TESTDIR"
cp -r /Users/daverapin/projects/opensource/libero/examples/default test_app
find test_app -name 'gleam.toml' -exec \
  sed -i.bak 's/name = "default"/name = "test_app"/g' {} \;
find test_app -name '*.bak' -delete
mv test_app/server/src/default.gleam test_app/server/src/test_app.gleam
mv test_app/server/test/default_test.gleam test_app/server/test/test_app_test.gleam
cd test_app/server
gleam build
cd ../../..
rm -rf "$TESTDIR"
cd /Users/daverapin/projects/opensource/libero
```

Expected: `gleam build` succeeds inside the renamed copy.

If the build fails, the rename logic in the script needs adjustment. Common gotchas:
- The server entry file's `pub fn main` is referenced by Gleam's build via the package's `name`. Renaming the file but not the package name (or vice versa) breaks the build.
- Test imports may reference `import handler` etc. — those don't change with rename.

- [ ] **Step 2: Test with actual download (requires the script to be on GitHub)**

This step can only run after the script is committed and pushed. For now, skip and commit:

### Task 6.3: Commit Phase 6

**Files:**
- All Phase 6 changes

- [ ] **Step 1: Stage and commit**

```sh
git add bin/new
git commit -m "Add bin/new scaffolding script

Downloads libero tarball, extracts examples/<template>, renames the
example to the user's project name, switches libero path-dep to hex
dep, runs git init. Standard curl|sh distribution pattern. Default
template is examples/default."
```

---

## Phase 7 — Update README and llms.txt

Goal: update getting-started, layout description, and command reference to reflect the new shape.

### Task 7.1: Update README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Replace the Getting Started section**

Find the "## Getting Started" heading. Replace its body (the code block showing `gleam run -m libero -- new my_app --web`) with:

```markdown
## Getting Started

Create a new project from the default starter:

```bash
curl -fsSL https://raw.githubusercontent.com/pairshaped/libero/main/bin/new | sh -s my_app
cd my_app
bin/dev
# Server running on http://localhost:8080
```

The starter is `examples/default/` from this repo. Pick a different example by passing its name:

```bash
curl -fsSL https://raw.githubusercontent.com/pairshaped/libero/main/bin/new | sh -s my_todos todos
```

Don't want to pipe a remote script to your shell? View the script first:
[`bin/new`](bin/new). It's bash, ~30 lines. Or download and inspect:

```bash
curl -fsSL https://raw.githubusercontent.com/pairshaped/libero/main/bin/new -o new
less new
sh new my_app
```
```

- [ ] **Step 2: Replace the Project Structure section**

Find "## Project Structure" and replace its tree + commentary. New version:

```markdown
## Project Structure

```
my_app/
├── bin/
│   ├── dev                          # codegen + run server
│   └── test                         # run server tests
├── server/
│   ├── gleam.toml                   # target=erlang, [tools.libero] config
│   └── src/
│       ├── my_app.gleam             # server entry (auto-generated, customizable)
│       ├── handler.gleam            # your RPC endpoints
│       ├── handler_context.gleam    # server context type
│       ├── page.gleam               # SSR load_page + render_page
│       └── generated/               # dispatch, websocket (auto-generated)
├── shared/
│   ├── gleam.toml                   # cross-target shared types + views
│   └── src/shared/
│       ├── router.gleam             # Route, parse_route, route_to_path
│       ├── types.gleam              # domain types used in handlers
│       └── views.gleam              # Model, Msg, view function (cross-target)
└── clients/
    └── web/
        ├── gleam.toml               # target=javascript
        └── src/
            ├── app.gleam            # Lustre client (hydrates SSR HTML)
            └── flags_ffi.mjs        # reads window.__LIBERO_FLAGS__
            └── generated/           # client RPC stubs (auto-generated)
```

Three peer Gleam packages (`server/`, `shared/`, `clients/web/`), each with its own `gleam.toml`. Matches Lustre's recommended fullstack shape with one extension: `clients/` is plural so libero supports multi-client apps.

`shared/` is target-agnostic: it compiles to both Erlang (used by the server) and JavaScript (used by the client). All types crossing the wire and all view functions live here.

`server/` runs `gleam run -m libero` to regenerate dispatch and client stubs. The `bin/dev` script wraps that plus `gleam build` and `gleam run` so you don't have to think about it.
```

- [ ] **Step 3: Update Commands section**

Find any section listing libero commands (search for `gleam run -m libero --`). The CLI is now single-purpose. Replace with:

```markdown
## Commands

From the project root:

- `bin/dev` — regenerate code, build, and start the server
- `bin/test` — run server tests

The `bin/dev` script does three things in order:

1. `cd server && gleam run -m libero` — regenerates dispatch, websocket, and client RPC stubs from your handler signatures.
2. `cd clients/web && gleam build --target javascript` — compiles the client SPA so the server can serve it from `/web/web/app.mjs`.
3. `cd server && gleam run` — starts the mist HTTP server on port 8080.

To run any step manually, the commands are above. Adding clients, editing routes, etc. — see `examples/default/README.md` for the per-task playbook.
```

- [ ] **Step 4: Verify no stale references remain**

```sh
grep -n "libero -- new\|libero -- add\|libero -- build\|libero -- gen\|--web" README.md
```

Expected: no matches. If any remain, update.

### Task 7.2: Update llms.txt

**Files:**
- Modify: `llms.txt`

- [ ] **Step 1: Find the layout section**

```sh
grep -n "src/server\|src/<app>\|tools.libero" llms.txt
```

Expected: several matches describing the old layout.

- [ ] **Step 2: Update the "Project Structure" or equivalent section**

Find the section that describes the project tree. Replace it with the same tree shown above in README.md. Keep llms.txt's terser style.

- [ ] **Step 3: Update command references**

```sh
grep -n "libero -- new\|libero -- add\|libero -- build\|libero -- gen" llms.txt
```

Apply these substitutions in `llms.txt`:

- `gleam run -m libero -- gen` → `gleam run -m libero`
- `gleam run -m libero -- build` → for build orchestration, point at `bin/dev`. Where the original text was specifically about code generation, drop the `-- build` and use `gleam run -m libero` (which now does only codegen).
- `gleam run -m libero -- new my_app --web` → `curl -fsSL https://raw.githubusercontent.com/pairshaped/libero/main/bin/new | sh -s my_app`
- `gleam run -m libero -- add <name> --target <t>` → "Add a client manually: create `clients/<name>/gleam.toml`, add `[tools.libero.clients.<name>]` to `server/gleam.toml`."

- [ ] **Step 4: Update "What Gets Generated" or similar sections**

The paths libero writes to changed: `src/server/generated/` is now `src/generated/` (inside the server package). Update any path references.

### Task 7.3: Run tests one last time

**Files:**
- Read-only

- [ ] **Step 1: Run the full library test suite**

```sh
gleam test
```

Expected: passes.

- [ ] **Step 2: Build both examples**

```sh
(cd examples/default/server && gleam build) && \
  (cd examples/default/clients/web && gleam build --target javascript) && \
  (cd examples/default/shared && gleam build) && \
  (cd examples/todos/server && gleam build) && \
  (cd examples/todos/clients/web && gleam build --target javascript) && \
  (cd examples/todos/shared && gleam build)
```

Expected: all builds succeed.

- [ ] **Step 3: Run example tests**

```sh
(cd examples/default && bin/test) && (cd examples/todos && bin/test)
```

Expected: passes for both.

### Task 7.4: Commit Phase 7

**Files:**
- All Phase 7 changes

- [ ] **Step 1: Stage and commit**

```sh
git add README.md llms.txt
git commit -m "Update README and llms.txt for three-peer layout

Getting-started uses curl|sh + bin/new. Project structure shows the
three-peer monorepo. Command reference points at bin/dev as the
daily-driver entry point. Old 'gleam run -m libero -- new/add/build'
incantations are gone."
```

---

## Phase 8 — Final verification

### Task 8.1: Full library test suite

**Files:**
- Read-only

- [ ] **Step 1: Run all tests**

```sh
gleam test
```

Expected: all tests pass.

- [ ] **Step 2: Run gleam format**

```sh
gleam format
```

Expected: clean (or the only changes are reformats to existing files we touched, which is fine).

- [ ] **Step 3: Run glinter**

```sh
gleam run -m glinter
```

Expected: clean.

### Task 8.2: Manual smoke test

**Files:**
- Read-only

- [ ] **Step 1: Smoke test the default example**

```sh
cd examples/default && bin/dev &
DEV_PID=$!
sleep 8
curl -sS http://localhost:8080/ > /tmp/libero_smoke.html
kill $DEV_PID
cd ../..

cat /tmp/libero_smoke.html | head -30
```

Expected: HTML response that includes `<h1>Hello from default</h1>`, a `<button>` with "Ping" text, and `<script type="module">` tags for the boot script.

If anything is missing, the SSR pipeline isn't working end-to-end — debug before declaring done.

### Task 8.3: Final commit and review

**Files:**
- Read-only

- [ ] **Step 1: Verify clean tree**

```sh
git status
```

Expected: clean. If there's a `*.bak` file or a build/ directory that crept in, clean it up.

- [ ] **Step 2: Review the commit list**

```sh
git log --oneline ^master HEAD
```

(Adjust against the merge base if not on master.)

Expected: one commit per phase, clean messages, no surprises.

The plan is complete. Hand off for review.

---

## Risks and gotchas to watch during implementation

- **Path depth on `libero = { path = "..." }`** in scaffolded gleam.tomls. Examples sit at `examples/<name>/server/` which is 3 dirs from libero repo root, so `path = "../../../../"`. If you misjudge depth, builds fail with confusing "package not found" errors. Count carefully.

- **Generated/codegen paths.** When you change config defaults in Phase 2, codegen reads the new defaults but old test fixtures still reflect the old paths. Phase 3 fixes the test, but if any other test reaches into `src/server/generated/` (in libero's own repo), it'll fail. Search and fix.

- **Gleam's path-dep resolution.** `path = "../shared"` works, but Gleam may cache builds at `build/` per package. If a build looks stale, `rm -rf build/` and rebuild.

- **`bin/new` script's sed quoting.** The script renames `default` to the user's project name. If the user picks a name with special regex characters (very unlikely but possible — `my-app`), the sed call could misfire. Document that project names should be lowercase letters, digits, underscore.

- **Modem dep.** The default example imports modem. Make sure modem is available on hex or as a path-dep before building.

- **`libero/ssr.boot_script` flag encoding.** The `flags: model` in `render_page` runs Erlang's term_to_binary. The model must be ETF-encodable. Plain records of strings, ints, atoms work; Dict/Set may not. The starter Model is fine.

- **`/web/web/app.mjs` URL.** First `/web` is the URL prefix matching the client name. Second `web` is the gleam package name. If you rename the client package or the URL scheme, both need to match.
