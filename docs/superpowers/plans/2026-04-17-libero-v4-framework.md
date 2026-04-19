# Libero v4 Framework Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Transform Libero from a library with manual codegen into a framework with CLI tooling, single-project structure (`core/` + `clients/`), and automatic code generation driven by `libero.toml`.

**Architecture:** The existing scanner/walker/codegen pipeline stays mostly intact. The main changes are: (1) a new `libero.toml` config layer replaces CLI flags, (2) the scanner reads from `src/core/` instead of a separate `shared/` package, (3) codegen outputs into `src/clients/<name>/generated/` for each declared client, and (4) new CLI commands (`new`, `add`, `gen`, `dev`, `build`) orchestrate everything. A new example (`examples/todos-v4/`) validates the framework structure end-to-end.

**Tech Stack:** Gleam, tom (TOML parser), glance (AST), simplifile, argv, mist, lustre

**Spec:** `docs/superpowers/specs/2026-04-17-libero-framework-design.md`

---

## File Structure

### New files
- `src/libero/toml_config.gleam` — Parse `libero.toml`, produce config for each client
- `src/libero/cli.gleam` — CLI command router (`new`, `add`, `gen`, `dev`, `build`)
- `src/libero/cli/new.gleam` — `libero new` scaffolding
- `src/libero/cli/add.gleam` — `libero add` client scaffolding
- `src/libero/cli/gen.gleam` — `libero gen` codegen orchestration
- `src/libero/cli/templates.gleam` — Starter app templates (handler, messages, SPA, CLI)
- `test/libero/toml_config_test.gleam` — TOML config tests
- `test/libero/cli_new_test.gleam` — Scaffold tests
- `test/libero/cli_add_test.gleam` — Client add tests
- `test/libero/cli_gen_test.gleam` — Gen orchestration tests
- `examples/todos-v4/` — Full v4-structure example

### Modified files
- `src/libero.gleam` — New entry point routing to CLI commands
- `src/libero/config.gleam` — Add `from_toml` path alongside existing CLI-flag path (backwards compat)
- `src/libero/scanner.gleam` — Support scanning `src/core/` (module path derivation changes)
- `src/libero/codegen.gleam` — Minor: accept per-client generated paths
- `gleam.toml` — Add `tom` dependency

---

## Phase 1: TOML Configuration

### Task 1: Add tom dependency

**Files:**
- Modify: `gleam.toml`

- [ ] **Step 1: Add tom to dependencies**

Add to the `[dependencies]` section of `gleam.toml`:

```toml
tom = "~> 2.0"
```

- [ ] **Step 2: Fetch dependencies**

Run: `gleam deps download`
Expected: tom package downloaded successfully

- [ ] **Step 3: Verify existing tests still pass**

Run: `gleam test`
Expected: All existing tests pass

- [ ] **Step 4: Commit**

```bash
git add gleam.toml manifest.toml
git commit -m "Add tom TOML parser dependency"
```

---

### Task 2: TOML config parser

**Files:**
- Create: `src/libero/toml_config.gleam`
- Create: `test/libero/toml_config_test.gleam`

- [ ] **Step 1: Write failing test for basic TOML parsing**

```gleam
// test/libero/toml_config_test.gleam

import libero/toml_config

pub fn parse_minimal_toml_test() {
  let toml = "
name = \"my_app\"
port = 3000
"
  let assert Ok(config) = toml_config.parse(toml)
  let assert "my_app" = config.name
  let assert 3000 = config.port
  let assert [] = config.clients
  let assert False = config.rest
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `gleam test -- --testfun parse_minimal_toml`
Expected: FAIL — module `libero/toml_config` not found

- [ ] **Step 3: Write minimal implementation**

```gleam
// src/libero/toml_config.gleam

//// Parse libero.toml into framework configuration.
////
//// Replaces CLI flag parsing for v4 framework mode. Each declared client
//// gets its own codegen config derived from its name and target.

import gleam/dict.{type Dict}
import gleam/list
import gleam/result
import tom

/// A declared client consumer.
pub type ClientConfig {
  ClientConfig(
    /// Client name, e.g. "web", "cli"
    name: String,
    /// Compilation target: "javascript" or "erlang"
    target: String,
  )
}

/// Parsed libero.toml.
pub type TomlConfig {
  TomlConfig(
    name: String,
    port: Int,
    rest: Bool,
    clients: List(ClientConfig),
  )
}

/// Parse a TOML string into a TomlConfig.
pub fn parse(input: String) -> Result(TomlConfig, String) {
  use parsed <- result.try(
    tom.parse(input)
    |> result.map_error(fn(_) { "TOML parse error" }),
  )
  use name <- result.try(
    tom.get_string(parsed, ["name"])
    |> result.map_error(fn(_) { "missing required field: name" }),
  )
  let port =
    tom.get_int(parsed, ["port"])
    |> result.unwrap(8080)
  let rest =
    tom.get_bool(parsed, ["server", "rest"])
    |> result.unwrap(False)
  let clients = parse_clients(parsed)
  Ok(TomlConfig(name:, port:, rest:, clients:))
}

/// Extract [clients.*] sections from parsed TOML.
/// tom.get_table returns Dict(String, Toml), so we use dict.keys
/// to iterate client names and look up their target.
fn parse_clients(parsed: Dict(String, tom.Toml)) -> List(ClientConfig) {
  case tom.get_table(parsed, ["clients"]) {
    Error(_) -> []
    Ok(clients_table) ->
      dict.keys(clients_table)
      |> list.filter_map(fn(name) {
        case tom.get_table(clients_table, [name]) {
          Error(_) -> Error(Nil)
          Ok(client_table) ->
            case tom.get_string(client_table, ["target"]) {
              Ok(target) -> Ok(ClientConfig(name:, target:))
              Error(_) -> Error(Nil)
            }
        }
      })
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `gleam test -- --testfun parse_minimal_toml`
Expected: PASS

- [ ] **Step 5: Write test for clients parsing**

```gleam
pub fn parse_with_clients_test() {
  let toml = "
name = \"my_app\"

[server]
rest = true

[clients.web]
target = \"javascript\"

[clients.cli]
target = \"erlang\"
"
  let assert Ok(config) = toml_config.parse(toml)
  let assert "my_app" = config.name
  let assert True = config.rest
  let assert 2 = list.length(config.clients)
  let assert Ok(web) = list.find(config.clients, fn(c) { c.name == "web" })
  let assert "javascript" = web.target
  let assert Ok(cli) = list.find(config.clients, fn(c) { c.name == "cli" })
  let assert "erlang" = cli.target
}
```

- [ ] **Step 6: Run test to verify it passes**

Run: `gleam test -- --testfun parse_with_clients`
Expected: PASS (implementation already handles this)

- [ ] **Step 7: Write test for missing name error**

```gleam
pub fn parse_missing_name_test() {
  let toml = "port = 3000"
  let assert Error("missing required field: name") = toml_config.parse(toml)
}
```

- [ ] **Step 8: Run test to verify it passes**

Run: `gleam test -- --testfun parse_missing_name`
Expected: PASS

- [ ] **Step 9: Commit**

```bash
git add src/libero/toml_config.gleam test/libero/toml_config_test.gleam
git commit -m "Add libero.toml parser with client config support"
```

---

### Task 3: TOML config to codegen config bridge

Build the bridge that converts a `TomlConfig` + client name into the existing `config.Config` type that the codegen pipeline expects. This lets us reuse all existing codegen without modification.

**Files:**
- Modify: `src/libero/toml_config.gleam`
- Create: `test/libero/toml_config_bridge_test.gleam`

- [ ] **Step 1: Write failing test for config bridge**

```gleam
// test/libero/toml_config_bridge_test.gleam

import gleam/option.{Some}
import libero/config.{WsPathOnly}
import libero/toml_config.{ClientConfig, TomlConfig}

pub fn to_codegen_config_javascript_client_test() {
  let toml_cfg = TomlConfig(
    name: "my_app",
    port: 3000,
    rest: False,
    clients: [ClientConfig(name: "web", target: "javascript")],
  )
  let assert Ok(cfg) = toml_config.to_codegen_config(
    toml_cfg,
    client: "web",
    ws_path: "/ws",
  )
  // Client generated path should point to src/clients/web/generated
  let assert "src/clients/web/generated" = cfg.client_generated
  // Server generated stays in src/core/generated
  let assert "src/core/generated" = cfg.server_generated
  // Scanner should scan src/core
  let assert Some("src/core") = cfg.shared_src
  // WS mode should be path-only
  let assert WsPathOnly(path: "/ws") = cfg.ws_mode
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `gleam test -- --testfun to_codegen_config_javascript`
Expected: FAIL — function `to_codegen_config` not found

- [ ] **Step 3: Implement the bridge function**

Add to `src/libero/toml_config.gleam`:

```gleam
import gleam/option.{None, Some}
import libero/config.{type Config, Config, WsPathOnly}

/// Convert a TomlConfig + client name into a codegen Config.
/// This bridges the v4 TOML config to the existing codegen pipeline.
pub fn to_codegen_config(
  toml_cfg: TomlConfig,
  client client_name: String,
  ws_path ws_path: String,
) -> Result(Config, String) {
  use client <- result.try(
    list.find(toml_cfg.clients, fn(c) { c.name == client_name })
    |> result.map_error(fn(_) { "client not found: " <> client_name }),
  )
  let client_generated = "src/clients/" <> client.name <> "/generated"
  let server_generated = "src/core/generated"
  let atoms_module = toml_cfg.name <> "@generated@rpc_atoms"
  let atoms_output = "src/" <> atoms_module <> ".erl"
  let register_relpath_prefix = "../../../../"
  Ok(Config(
    ws_mode: WsPathOnly(path: ws_path),
    namespace: None,
    client_root: "src/clients/" <> client.name,
    atoms_output:,
    atoms_module:,
    config_output: client_generated <> "/rpc_config.gleam",
    register_gleam_output: client_generated <> "/rpc_register.gleam",
    register_ffi_output: client_generated <> "/rpc_register_ffi.mjs",
    register_relpath_prefix:,
    shared_src: Some("src/core"),
    server_src: Some("src"),
    server_generated:,
    client_generated:,
  ))
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `gleam test -- --testfun to_codegen_config_javascript`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/libero/toml_config.gleam test/libero/toml_config_bridge_test.gleam
git commit -m "Add TOML config to codegen config bridge"
```

---

## Phase 2: Scanner Updates

### Task 4: Update scanner to work with core/ directory

The scanner currently expects to scan `shared/src/shared/` and derives module paths like `shared/todos`. For v4, it needs to scan `src/core/` and derive paths like `core/todos`. The key change is in `derive_module_path` and how the scan root is used.

**Files:**
- Modify: `src/libero/scanner.gleam`
- Modify: `test/libero/scanner_test.gleam`

- [ ] **Step 1: Write failing test for core/ module path derivation**

Add to `test/libero/scanner_test.gleam`:

```gleam
pub fn derive_module_path_core_test() {
  // v4 framework structure: src/core/todos.gleam -> core/todos
  let assert "core/todos" =
    scanner.derive_module_path(file_path: "src/core/todos.gleam")
  let assert "core/messages/admin" =
    scanner.derive_module_path(file_path: "src/core/messages/admin.gleam")
}
```

- [ ] **Step 2: Run test to verify it passes (or fails)**

Run: `gleam test -- --testfun derive_module_path_core`
Expected: PASS — `derive_module_path` already strips everything before `/src/` and removes `.gleam`, so `src/core/todos.gleam` → `core/todos` should work.

If it passes, the scanner already handles v4 paths correctly. The existing `scan_message_modules` function takes a `shared_src` parameter — for v4, we pass `src/core` instead of `../shared/src/shared`. The scanner doesn't care about the directory name, just the path.

- [ ] **Step 3: Write test for handler discovery in core/ structure**

In v4, handlers live alongside messages in `src/core/` (or subdirectories). The handler scanner currently scans `server_src` which is `src/`. For v4, it should also be `src/` — handlers in `src/core/handlers/` will be found since the scanner walks recursively.

Add to `test/libero/scanner_test.gleam`:

```gleam
pub fn derive_module_path_handler_test() {
  // v4: handlers in src/core/ are discovered normally
  let assert "core/todos_handler" =
    scanner.derive_module_path(file_path: "src/core/todos_handler.gleam")
}
```

- [ ] **Step 4: Run test**

Run: `gleam test -- --testfun derive_module_path_handler`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add test/libero/scanner_test.gleam
git commit -m "Add scanner tests for v4 core/ module path derivation"
```

---

## Phase 3: CLI Framework

### Task 5: CLI command router

**Files:**
- Create: `src/libero/cli.gleam`
- Modify: `src/libero.gleam`

- [ ] **Step 1: Create CLI router**

```gleam
// src/libero/cli.gleam

//// CLI command router for the Libero framework.
////
//// Routes `gleam run -m libero -- <command> [args]` to the appropriate
//// handler. Falls back to legacy codegen mode when no command is given
//// (backwards compatibility with v3 CLI-flag invocations).

import argv
import gleam/io

pub type Command {
  New(name: String)
  Add(name: String, target: String)
  Gen
  Dev
  Build
  Legacy
}

/// Parse CLI arguments into a Command.
pub fn parse_command() -> Command {
  let args = argv.load().arguments
  case args {
    ["new", name, ..] -> New(name:)
    ["add", name, "--target", target, ..] -> Add(name:, target:)
    ["add", name, ..] -> {
      io.println_error("error: --target is required")
      io.println_error("  Usage: libero add <name> --target <javascript|erlang>")
      Add(name:, target: "")
    }
    ["gen", ..] -> Gen
    ["dev", ..] -> Dev
    ["build", ..] -> Build
    _ -> Legacy
  }
}
```

- [ ] **Step 2: Update libero.gleam entry point to route commands**

Replace the body of `main()` in `src/libero.gleam` to dispatch to the CLI router, falling back to the existing legacy codegen for backwards compatibility:

```gleam
// src/libero.gleam

import gleam/int
import gleam/io
import gleam/list
import gleam/option
import gleam/result
import libero/cli
import libero/codegen
import libero/config
import libero/gen_error
import libero/scanner
import libero/walker

pub fn main() -> Nil {
  let Nil = trap_signals()
  case cli.parse_command() {
    cli.New(name:) -> {
      io.println("libero new " <> name <> " (not yet implemented)")
      Nil
    }
    cli.Add(name:, target:) -> {
      io.println(
        "libero add " <> name <> " --target " <> target
        <> " (not yet implemented)",
      )
      Nil
    }
    cli.Gen -> {
      io.println("libero gen (not yet implemented)")
      Nil
    }
    cli.Dev -> {
      io.println("libero dev (not yet implemented)")
      Nil
    }
    cli.Build -> {
      io.println("libero build (not yet implemented)")
      Nil
    }
    cli.Legacy -> legacy_main()
  }
}

/// Original v3 codegen entry point, preserved for backwards compatibility.
fn legacy_main() -> Nil {
  let config = config.parse_config()
  case config.shared_src {
    option.Some(shared_src) -> {
      io.println("libero: scanning shared message modules at " <> shared_src)
      case legacy_run(config: config, shared_src: shared_src) {
        Ok(count) -> {
          io.println(
            "libero: done. processed "
            <> int.to_string(count)
            <> " message module(s)",
          )
          let _halt = halt(0)
        }
        Error(errors) -> {
          list.each(errors, gen_error.print_error)
          let count = int.to_string(list.length(errors))
          io.println_error("")
          io.println_error(
            "libero: " <> count <> " error(s), no files generated",
          )
          let _halt = halt(1)
        }
      }
    }
    option.None -> {
      io.println_error("error: --shared is required")
      io.println_error("")
      io.println_error("  Example:")
      io.println_error(
        "    gleam run -m libero -- --ws-path=/ws/admin --shared=../shared --server=.",
      )
      let _halt = halt(1)
    }
  }
}

/// Legacy v3 codegen run function.
fn legacy_run(
  config config: config.Config,
  shared_src shared_src: String,
) -> Result(Int, List(gen_error.GenError)) {
  use #(message_modules, module_files) <- result.try(
    scanner.scan_message_modules(shared_src: shared_src),
  )
  io.println(
    "libero: found "
    <> int.to_string(list.length(message_modules))
    <> " message module(s)",
  )

  let server_src = option.unwrap(config.server_src, "src")
  use message_modules <- result.try(scanner.validate_conventions(
    message_modules: message_modules,
    server_src: server_src,
  ))
  use _ <- result.try(scanner.validate_msg_from_server_fields(message_modules:))

  use discovered <- result.try(walker.walk_message_registry_types(
    message_modules: message_modules,
    module_files: module_files,
  ))
  io.println(
    "libero: discovered "
    <> int.to_string(list.length(discovered))
    <> " type variant(s) for registration",
  )

  use _ <- result.try(
    codegen.write_dispatch(
      message_modules: message_modules,
      server_generated: config.server_generated,
      atoms_module: config.atoms_module,
    )
    |> result.map_error(fn(e) { [e] }),
  )
  use _ <- result.try(codegen.write_send_functions(
    message_modules: message_modules,
    client_generated: config.client_generated,
  ))
  use _ <- result.try(codegen.write_push_wrappers(
    message_modules: message_modules,
    server_generated: config.server_generated,
  ))
  use _ <- result.try(
    codegen.write_websocket(server_generated: config.server_generated)
    |> result.map_error(fn(e) { [e] }),
  )
  use _ <- result.try(
    codegen.write_config(config: config)
    |> result.map_error(fn(e) { [e] }),
  )
  use _ <- result.try(codegen.write_register(
    config: config,
    discovered: discovered,
  ))
  use _ <- result.try(
    codegen.write_atoms(config: config, discovered: discovered)
    |> result.map_error(fn(e) { [e] }),
  )
  use _ <- result.try(
    codegen.write_ssr_flags(client_generated: config.client_generated)
    |> result.map_error(fn(e) { [e] }),
  )
  Ok(list.length(message_modules))
}

@external(erlang, "erlang", "halt")
fn halt(code: Int) -> Nil

@external(erlang, "libero_ffi", "trap_signals")
fn trap_signals() -> Nil
```

- [ ] **Step 3: Verify legacy mode still works**

Run: `gleam test`
Expected: All existing tests pass. The legacy codegen path is unchanged.

- [ ] **Step 4: Commit**

```bash
git add src/libero.gleam src/libero/cli.gleam
git commit -m "Add CLI command router with legacy fallback"
```

---

### Task 6: `libero new` scaffolding

**Files:**
- Create: `src/libero/cli/new.gleam`
- Create: `src/libero/cli/templates.gleam`
- Modify: `src/libero/cli.gleam`
- Create: `test/libero/cli_new_test.gleam`

- [ ] **Step 1: Write failing test for project scaffolding**

```gleam
// test/libero/cli_new_test.gleam

import gleam/string
import libero/cli/new as cli_new
import simplifile

pub fn scaffold_project_test() {
  let dir = "test/tmp/scaffold_test"
  // Clean up from any previous run
  let _ = simplifile.delete(dir)

  let assert Ok(Nil) = cli_new.scaffold(name: "my_app", path: dir)

  // Verify files exist
  let assert Ok(True) = simplifile.is_file(dir <> "/libero.toml")
  let assert Ok(True) = simplifile.is_file(dir <> "/gleam.toml")
  let assert Ok(True) = simplifile.is_directory(dir <> "/src/core")

  // Verify libero.toml content
  let assert Ok(toml) = simplifile.read(dir <> "/libero.toml")
  let assert True = string.contains(toml, "name = \"my_app\"")

  // Verify gleam.toml content
  let assert Ok(gleam_toml) = simplifile.read(dir <> "/gleam.toml")
  let assert True = string.contains(gleam_toml, "name = \"my_app\"")
  let assert True = string.contains(gleam_toml, "target = \"erlang\"")

  // Verify starter files
  let assert Ok(True) = simplifile.is_file(dir <> "/src/core/todos.gleam")
  let assert Ok(True) = simplifile.is_file(dir <> "/src/core/todos_handler.gleam")
  let assert Ok(True) = simplifile.is_file(dir <> "/src/core/shared_state.gleam")
  let assert Ok(True) = simplifile.is_file(dir <> "/src/core/app_error.gleam")

  // Clean up
  let _ = simplifile.delete(dir)
  Nil
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `gleam test -- --testfun scaffold_project`
Expected: FAIL — module not found

- [ ] **Step 3: Create templates module**

```gleam
// src/libero/cli/templates.gleam

//// Starter file templates for scaffolding.

pub fn libero_toml(name name: String) -> String {
  "name = \"" <> name <> "\"
port = 8080
"
}

pub fn gleam_toml(name name: String) -> String {
  "name = \"" <> name <> "\"
version = \"0.1.0\"
target = \"erlang\"

[dependencies]
gleam_stdlib = \">= 0.69.0 and < 1.0.0\"
libero = { path = \"../libero\" }
"
}

pub fn starter_messages() -> String {
  "pub type Todo {
  Todo(id: Int, title: String, completed: Bool)
}

pub type TodoParams {
  TodoParams(title: String)
}

pub type TodoError {
  NotFound
  TitleRequired
}

pub type MsgFromClient {
  Create(params: TodoParams)
  Toggle(id: Int)
  Delete(id: Int)
  LoadAll
}

pub type MsgFromServer {
  TodoCreated(Result(Todo, TodoError))
  TodoToggled(Result(Todo, TodoError))
  TodoDeleted(Result(Int, TodoError))
  TodosLoaded(Result(List(Todo), TodoError))
}
"
}

pub fn starter_handler() -> String {
  "import core/todos.{
  type MsgFromClient, type MsgFromServer, type TodoError,
  Create, Delete, LoadAll, Toggle,
  TodoCreated, TodoDeleted, TodoToggled, TodosLoaded,
  NotFound, TitleRequired,
}
import core/shared_state.{type SharedState}
import core/app_error.{type AppError}

pub fn update_from_client(
  msg msg: MsgFromClient,
  state state: SharedState,
) -> Result(#(MsgFromServer, SharedState), AppError) {
  case msg {
    Create(params:) -> Ok(#(TodoCreated(Ok(todos.Todo(1, params.title, False))), state))
    Toggle(_id) -> Ok(#(TodoToggled(Error(NotFound)), state))
    Delete(_id) -> Ok(#(TodoDeleted(Error(NotFound)), state))
    LoadAll -> Ok(#(TodosLoaded(Ok([])), state))
  }
}
"
}

pub fn starter_shared_state() -> String {
  "pub type SharedState {
  SharedState
}

pub fn new() -> SharedState {
  SharedState
}
"
}

pub fn starter_app_error() -> String {
  "pub type AppError {
  AppError(String)
}
"
}

pub fn starter_spa(name name: String) -> String {
  "import lustre
import lustre/element
import lustre/element/html

pub fn main() {
  let app = lustre.element(view())
  let assert Ok(_) = lustre.start(app, \"#app\", Nil)
  Nil
}

fn view() -> element.Element(msg) {
  html.div([], [
    html.h1([], [html.text(\"" <> name <> "\")]),
    html.p([], [html.text(\"Edit src/clients/" <> name <> "/app.gleam to get started.\")]),
  ])
}
"
}

pub fn starter_cli() -> String {
  "import gleam/io

pub fn main() {
  io.println(\"CLI client ready. Add your commands here.\")
}
"
}
```

- [ ] **Step 4: Create new.gleam scaffolder**

```gleam
// src/libero/cli/new.gleam

//// `libero new` — scaffold a new Libero project.

import libero/cli/templates
import simplifile

/// Scaffold a new Libero project at the given path.
pub fn scaffold(name name: String, path path: String) -> Result(Nil, String) {
  let core_dir = path <> "/src/core"
  use _ <- try_write_dir(core_dir)
  use _ <- try_write(path <> "/libero.toml", templates.libero_toml(name:))
  use _ <- try_write(path <> "/gleam.toml", templates.gleam_toml(name:))
  use _ <- try_write(core_dir <> "/todos.gleam", templates.starter_messages())
  use _ <- try_write(
    core_dir <> "/todos_handler.gleam",
    templates.starter_handler(),
  )
  use _ <- try_write(
    core_dir <> "/shared_state.gleam",
    templates.starter_shared_state(),
  )
  use _ <- try_write(core_dir <> "/app_error.gleam", templates.starter_app_error())
  Ok(Nil)
}

fn try_write_dir(
  path: String,
  next: fn(Nil) -> Result(Nil, String),
) -> Result(Nil, String) {
  case simplifile.create_directory_all(path) {
    Ok(Nil) -> next(Nil)
    Error(e) -> Error("failed to create directory " <> path <> ": " <> simplifile.describe_error(e))
  }
}

fn try_write(
  path: String,
  content: String,
  next: fn(Nil) -> Result(Nil, String),
) -> Result(Nil, String) {
  case simplifile.write(path, content) {
    Ok(Nil) -> next(Nil)
    Error(e) -> Error("failed to write " <> path <> ": " <> simplifile.describe_error(e))
  }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `gleam test -- --testfun scaffold_project`
Expected: PASS

- [ ] **Step 6: Wire up `libero new` in the CLI router**

Update the `New` case in `src/libero.gleam`:

```gleam
    cli.New(name:) -> {
      case cli_new.scaffold(name:, path: name) {
        Ok(Nil) -> {
          io.println("Created " <> name <> "/")
          io.println("  src/core/todos.gleam — starter messages")
          io.println("  src/core/todos_handler.gleam — starter handler")
          io.println("")
          io.println("Next: cd " <> name <> " && libero add web --target javascript")
        }
        Error(msg) -> {
          io.println_error("error: " <> msg)
          let _halt = halt(1)
        }
      }
      Nil
    }
```

Add import: `import libero/cli/new as cli_new`

- [ ] **Step 7: Verify all tests pass**

Run: `gleam test`
Expected: All tests pass

- [ ] **Step 8: Commit**

```bash
git add src/libero/cli/new.gleam src/libero/cli/templates.gleam src/libero.gleam test/libero/cli_new_test.gleam
git commit -m "Add libero new scaffolding with starter templates"
```

---

### Task 7: `libero add` client scaffolding

**Files:**
- Create: `src/libero/cli/add.gleam`
- Modify: `src/libero.gleam`
- Create: `test/libero/cli_add_test.gleam`

- [ ] **Step 1: Write failing test**

```gleam
// test/libero/cli_add_test.gleam

import gleam/string
import libero/cli/add as cli_add
import simplifile

pub fn add_javascript_client_test() {
  let dir = "test/tmp/add_js_test"
  let _ = simplifile.delete(dir)
  let _ = simplifile.create_directory_all(dir)
  // Create a minimal libero.toml
  let _ = simplifile.write(dir <> "/libero.toml", "name = \"my_app\"\n")

  let assert Ok(Nil) = cli_add.add_client(
    project_path: dir,
    name: "web",
    target: "javascript",
  )

  // Verify directory created
  let assert Ok(True) = simplifile.is_directory(dir <> "/src/clients/web")

  // Verify starter app created
  let assert Ok(True) = simplifile.is_file(dir <> "/src/clients/web/app.gleam")

  // Verify libero.toml updated
  let assert Ok(toml) = simplifile.read(dir <> "/libero.toml")
  let assert True = string.contains(toml, "[clients.web]")
  let assert True = string.contains(toml, "target = \"javascript\"")

  let _ = simplifile.delete(dir)
  Nil
}

pub fn add_erlang_client_test() {
  let dir = "test/tmp/add_erl_test"
  let _ = simplifile.delete(dir)
  let _ = simplifile.create_directory_all(dir)
  let _ = simplifile.write(dir <> "/libero.toml", "name = \"my_app\"\n")

  let assert Ok(Nil) = cli_add.add_client(
    project_path: dir,
    name: "cli",
    target: "erlang",
  )

  let assert Ok(True) = simplifile.is_file(dir <> "/src/clients/cli/main.gleam")

  let _ = simplifile.delete(dir)
  Nil
}

pub fn add_skips_existing_app_test() {
  let dir = "test/tmp/add_skip_test"
  let _ = simplifile.delete(dir)
  let _ = simplifile.create_directory_all(dir <> "/src/clients/web")
  let _ = simplifile.write(dir <> "/libero.toml", "name = \"my_app\"\n")
  let _ = simplifile.write(dir <> "/src/clients/web/app.gleam", "// custom app")

  let assert Ok(Nil) = cli_add.add_client(
    project_path: dir,
    name: "web",
    target: "javascript",
  )

  // Should NOT overwrite existing file
  let assert Ok("// custom app") = simplifile.read(dir <> "/src/clients/web/app.gleam")

  let _ = simplifile.delete(dir)
  Nil
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `gleam test -- --testfun add_javascript_client`
Expected: FAIL — module not found

- [ ] **Step 3: Implement add.gleam**

```gleam
// src/libero/cli/add.gleam

//// `libero add` — add a client to an existing Libero project.

import gleam/result
import gleam/string
import libero/cli/templates
import simplifile

/// Add a named client with a target to the project.
/// Creates the client directory, writes a starter app (if empty),
/// and appends the client config to libero.toml.
pub fn add_client(
  project_path path: String,
  name name: String,
  target target: String,
) -> Result(Nil, String) {
  let client_dir = path <> "/src/clients/" <> name
  use _ <- try_mkdir(client_dir)
  // Write starter app only if no files exist yet
  let starter = case target {
    "javascript" -> #("app.gleam", templates.starter_spa(name:))
    _ -> #("main.gleam", templates.starter_cli())
  }
  let app_path = client_dir <> "/" <> starter.0
  use _ <- try_write_if_missing(app_path, starter.1)
  // Append client config to libero.toml
  use _ <- try_append_toml(path <> "/libero.toml", name, target)
  Ok(Nil)
}

fn try_mkdir(
  path: String,
  next: fn(Nil) -> Result(Nil, String),
) -> Result(Nil, String) {
  case simplifile.create_directory_all(path) {
    Ok(Nil) -> next(Nil)
    Error(e) ->
      Error(
        "failed to create " <> path <> ": " <> simplifile.describe_error(e),
      )
  }
}

fn try_write_if_missing(
  path: String,
  content: String,
  next: fn(Nil) -> Result(Nil, String),
) -> Result(Nil, String) {
  case simplifile.is_file(path) |> result.unwrap(False) {
    True -> next(Nil)
    False ->
      case simplifile.write(path, content) {
        Ok(Nil) -> next(Nil)
        Error(e) ->
          Error(
            "failed to write " <> path <> ": " <> simplifile.describe_error(e),
          )
      }
  }
}

fn try_append_toml(
  path: String,
  name: String,
  target: String,
  next: fn(Nil) -> Result(Nil, String),
) -> Result(Nil, String) {
  let section =
    "\n[clients." <> name <> "]\ntarget = \"" <> target <> "\"\n"
  use existing <- try_read(path)
  // Only append if section doesn't already exist
  case string.contains(existing, "[clients." <> name <> "]") {
    True -> next(Nil)
    False ->
      case simplifile.write(path, existing <> section) {
        Ok(Nil) -> next(Nil)
        Error(e) ->
          Error(
            "failed to update " <> path <> ": " <> simplifile.describe_error(e),
          )
      }
  }
}

fn try_read(
  path: String,
  next: fn(String) -> Result(Nil, String),
) -> Result(Nil, String) {
  case simplifile.read(path) {
    Ok(content) -> next(content)
    Error(e) ->
      Error("failed to read " <> path <> ": " <> simplifile.describe_error(e))
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `gleam test -- --testfun add_`
Expected: All three add tests pass

- [ ] **Step 5: Wire up `libero add` in the CLI router**

Update the `Add` case in `src/libero.gleam`:

```gleam
    cli.Add(name:, target:) -> {
      case target {
        "" -> Nil
        _ ->
          case cli_add.add_client(project_path: ".", name:, target:) {
            Ok(Nil) -> {
              io.println("Added client: " <> name <> " (target: " <> target <> ")")
              io.println("  src/clients/" <> name <> "/")
              Nil
            }
            Error(msg) -> {
              io.println_error("error: " <> msg)
              let _halt = halt(1)
              Nil
            }
          }
      }
    }
```

Add import: `import libero/cli/add as cli_add`

- [ ] **Step 6: Verify all tests pass**

Run: `gleam test`
Expected: All tests pass

- [ ] **Step 7: Commit**

```bash
git add src/libero/cli/add.gleam src/libero.gleam test/libero/cli_add_test.gleam
git commit -m "Add libero add client scaffolding"
```

---

## Phase 4: `libero gen` — TOML-driven Codegen

### Task 8: `libero gen` command

This is the core task — wire `libero gen` to read `libero.toml`, scan `src/core/` for messages, and generate stubs for each declared client. Reuses the entire existing codegen pipeline via the config bridge from Task 3.

**Files:**
- Create: `src/libero/cli/gen.gleam`
- Modify: `src/libero.gleam`

- [ ] **Step 1: Implement gen.gleam**

```gleam
// src/libero/cli/gen.gleam

//// `libero gen` — run codegen for all declared clients.
////
//// Reads libero.toml, scans src/core/ for message types, and generates
//// typed stubs into each client's generated/ directory.

import gleam/int
import gleam/io
import gleam/list
import gleam/option
import gleam/result
import libero/codegen
import libero/gen_error
import libero/scanner
import libero/toml_config.{type ClientConfig, type TomlConfig}
import libero/walker
import simplifile

/// Run codegen for all clients declared in libero.toml.
pub fn run(project_path project_path: String) -> Result(Nil, String) {
  // Read and parse libero.toml
  let toml_path = project_path <> "/libero.toml"
  use toml_str <- try_read(toml_path)
  use toml_cfg <- try_parse(toml_str)

  case toml_cfg.clients {
    [] -> {
      io.println("libero gen: no clients declared in libero.toml")
      Ok(Nil)
    }
    clients -> {
      let core_src = project_path <> "/src/core"
      // Scan core/ for message modules
      use #(message_modules, module_files) <- try_scan(core_src)
      io.println(
        "libero: found "
        <> int.to_string(list.length(message_modules))
        <> " message module(s) in src/core/",
      )

      // Validate conventions
      let server_src = project_path <> "/src"
      use message_modules <- try_validate(message_modules, server_src)
      use _ <- try_validate_fields(message_modules)

      // Walk types for registration
      use discovered <- try_walk(message_modules, module_files)

      // Generate for each client
      use _ <- try_gen_clients(clients, toml_cfg, message_modules, discovered)

      io.println("libero: done")
      Ok(Nil)
    }
  }
}

fn try_read(
  path: String,
  next: fn(String) -> Result(Nil, String),
) -> Result(Nil, String) {
  case simplifile.read(path) {
    Ok(content) -> next(content)
    Error(_) -> Error("cannot read " <> path)
  }
}

fn try_parse(
  toml_str: String,
  next: fn(TomlConfig) -> Result(Nil, String),
) -> Result(Nil, String) {
  case toml_config.parse(toml_str) {
    Ok(cfg) -> next(cfg)
    Error(msg) -> Error(msg)
  }
}

fn try_scan(
  core_src: String,
  next: fn(#(List(scanner.MessageModule), _)) -> Result(Nil, String),
) -> Result(Nil, String) {
  case scanner.scan_message_modules(shared_src: core_src) {
    Ok(result) -> next(result)
    Error(errors) -> {
      list.each(errors, gen_error.print_error)
      Error("failed to scan message modules")
    }
  }
}

fn try_validate(
  message_modules: List(scanner.MessageModule),
  server_src: String,
  next: fn(List(scanner.MessageModule)) -> Result(Nil, String),
) -> Result(Nil, String) {
  case scanner.validate_conventions(message_modules:, server_src:) {
    Ok(modules) -> next(modules)
    Error(errors) -> {
      list.each(errors, gen_error.print_error)
      Error("convention validation failed")
    }
  }
}

fn try_validate_fields(
  message_modules: List(scanner.MessageModule),
  next: fn(Nil) -> Result(Nil, String),
) -> Result(Nil, String) {
  case scanner.validate_msg_from_server_fields(message_modules:) {
    Ok(Nil) -> next(Nil)
    Error(errors) -> {
      list.each(errors, gen_error.print_error)
      Error("MsgFromServer field validation failed")
    }
  }
}

fn try_walk(
  message_modules: List(scanner.MessageModule),
  module_files: _,
  next: fn(List(walker.DiscoveredVariant)) -> Result(Nil, String),
) -> Result(Nil, String) {
  case walker.walk_message_registry_types(message_modules:, module_files:) {
    Ok(discovered) -> next(discovered)
    Error(errors) -> {
      list.each(errors, gen_error.print_error)
      Error("type walking failed")
    }
  }
}

fn try_gen_clients(
  clients: List(ClientConfig),
  toml_cfg: TomlConfig,
  message_modules: List(scanner.MessageModule),
  discovered: List(walker.DiscoveredVariant),
  next: fn(Nil) -> Result(Nil, String),
) -> Result(Nil, String) {
  let results =
    list.map(clients, fn(client) {
      gen_client(client:, toml_cfg:, message_modules:, discovered:)
    })
  case list.find(results, result.is_error) {
    Ok(Error(msg)) -> Error(msg)
    _ -> next(Nil)
  }
}

fn gen_client(
  client client: ClientConfig,
  toml_cfg toml_cfg: TomlConfig,
  message_modules message_modules: List(scanner.MessageModule),
  discovered discovered: List(walker.DiscoveredVariant),
) -> Result(Nil, String) {
  io.println("libero: generating stubs for client: " <> client.name)
  use config <- result.try(toml_config.to_codegen_config(
    toml_cfg,
    client: client.name,
    ws_path: "/ws",
  ))

  // Ensure generated directory exists
  let _ = simplifile.create_directory_all(config.client_generated)
  let _ = simplifile.create_directory_all(config.server_generated)

  // Generate dispatch (once, not per-client, but safe to overwrite)
  let _ =
    codegen.write_dispatch(
      message_modules:,
      server_generated: config.server_generated,
      atoms_module: config.atoms_module,
    )

  // Generate client send stubs
  use _ <- try_codegen(codegen.write_send_functions(
    message_modules:,
    client_generated: config.client_generated,
  ))

  // Generate push wrappers
  let _ =
    codegen.write_push_wrappers(
      message_modules:,
      server_generated: config.server_generated,
    )

  // Generate websocket handler
  let _ = codegen.write_websocket(server_generated: config.server_generated)

  // Generate config
  let _ = codegen.write_config(config:)

  // Generate type registration
  use _ <- try_codegen(codegen.write_register(config:, discovered:))

  // Generate atoms
  let _ = codegen.write_atoms(config:, discovered:)

  // Generate SSR flags
  let _ = codegen.write_ssr_flags(client_generated: config.client_generated)

  Ok(Nil)
}

fn try_codegen(
  result: Result(Nil, List(gen_error.GenError)),
  next: fn(Nil) -> Result(Nil, String),
) -> Result(Nil, String) {
  case result {
    Ok(Nil) -> next(Nil)
    Error(errors) -> {
      list.each(errors, gen_error.print_error)
      Error("codegen failed")
    }
  }
}
```

- [ ] **Step 2: Wire up `libero gen` in the CLI router**

Update the `Gen` case in `src/libero.gleam`:

```gleam
    cli.Gen -> {
      case cli_gen.run(project_path: ".") {
        Ok(Nil) -> Nil
        Error(msg) -> {
          io.println_error("error: " <> msg)
          let _halt = halt(1)
          Nil
        }
      }
    }
```

Add import: `import libero/cli/gen as cli_gen`

- [ ] **Step 3: Verify all tests pass**

Run: `gleam test`
Expected: All tests pass

- [ ] **Step 4: Commit**

```bash
git add src/libero/cli/gen.gleam src/libero.gleam
git commit -m "Add libero gen command with TOML-driven codegen"
```

---

## Phase 5: End-to-End Validation

### Task 9: Create todos-v4 example

Create a working example using the v4 framework structure. This validates that the entire pipeline works.

**Files:**
- Create: `examples/todos-v4/libero.toml`
- Create: `examples/todos-v4/gleam.toml`
- Create: `examples/todos-v4/src/core/todos.gleam` (copy from `examples/todos/shared/src/shared/todos.gleam`)
- Create: `examples/todos-v4/src/core/todos_handler.gleam` (adapted from `examples/todos/server/src/server/store.gleam`)
- Create: `examples/todos-v4/src/core/shared_state.gleam`
- Create: `examples/todos-v4/src/core/app_error.gleam`
- Create: `examples/todos-v4/src/clients/web/app.gleam` (adapted from `examples/todos/client/src/client/app.gleam`)

- [ ] **Step 1: Create libero.toml**

```toml
name = "todos_v4"
port = 8080

[clients.web]
target = "javascript"
```

Write to `examples/todos-v4/libero.toml`.

- [ ] **Step 2: Create gleam.toml**

```toml
name = "todos_v4"
version = "0.1.0"
target = "erlang"

[dependencies]
gleam_stdlib = ">= 0.69.0 and < 1.0.0"
libero = { path = "../../" }
mist = "~> 6.0"
wisp = "~> 2.2"
gleam_erlang = "~> 1.0"
```

Write to `examples/todos-v4/gleam.toml`.

- [ ] **Step 3: Copy and adapt core modules**

Copy `examples/todos/shared/src/shared/todos.gleam` to `examples/todos-v4/src/core/todos.gleam`. No changes needed — the types are the same.

Copy `examples/todos/server/src/server/store.gleam` to `examples/todos-v4/src/core/todos_handler.gleam`. Update imports from `shared/todos` to `core/todos` and from `server/shared_state` to `core/shared_state`.

Copy `examples/todos/server/src/server/shared_state.gleam` to `examples/todos-v4/src/core/shared_state.gleam`. Update module path in any self-references.

Copy `examples/todos/server/src/server/app_error.gleam` to `examples/todos-v4/src/core/app_error.gleam`.

- [ ] **Step 4: Run libero gen from the example directory**

```bash
cd examples/todos-v4
gleam run -m libero -- gen
```

Expected: Libero reads `libero.toml`, scans `src/core/`, generates stubs into `src/clients/web/generated/`.

- [ ] **Step 5: Verify generated files exist**

```bash
ls src/clients/web/generated/
```

Expected: `rpc_config.gleam`, `rpc_register.gleam`, `rpc_register_ffi.mjs`, and a module-specific send stub (e.g., `todos.gleam`).

Also verify server-side generated files:
```bash
ls src/core/generated/
```

Expected: `dispatch.gleam`, `websocket.gleam`, push wrapper.

- [ ] **Step 6: Commit**

```bash
git add examples/todos-v4/
git commit -m "Add todos-v4 example validating framework structure"
```

---

### Task 10: Clean up and verify

**Files:**
- All test files

- [ ] **Step 1: Run the full test suite**

Run: `gleam test`
Expected: All tests pass

- [ ] **Step 2: Run the linter**

Run: `gleam run -m glinter`
Expected: No errors

- [ ] **Step 3: Clean up test temp directories**

Verify that test cleanup in `cli_new_test.gleam` and `cli_add_test.gleam` is working. Check that `test/tmp/` doesn't persist after tests.

- [ ] **Step 4: Add .gitignore for test tmp**

Add to `.gitignore`:
```
test/tmp/
```

- [ ] **Step 5: Final commit**

```bash
git add -A
git commit -m "Clean up v4 framework implementation"
```

---

## Future Tasks (Not in This Plan)

These are noted for planning purposes but are separate implementation efforts:

1. **`libero dev`** — file watcher + auto-rebuild + server start. Depends on fswatch or similar.
2. **`libero build`** — production compilation of server + all client packages.
3. **Server bootstrap generation** — Libero generates the Mist server entry point so the developer doesn't write `server.gleam` at all.
4. **REST endpoint generation** — auto-generate JSON HTTP endpoints when `rest = true`.
5. **Migrate todos example** — fully replace `examples/todos/` three-package structure with v4.
6. **Update README** — framework-first documentation.
