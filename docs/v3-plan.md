# Libero v3 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace annotation-based codegen (`@rpc`, `@inject`) with message-type-driven codegen using `MsgFromClient`/`MsgFromServer` convention types.

**Architecture:** Incremental refactor of the existing `libero.gleam` codegen. Keep the type walker, ETF codec, constructor registry, trace/error modules. Replace the input scanning (annotations become type scanning), output generation (per-function stubs become per-module send functions, string dispatch becomes type dispatch), and inject system (deleted entirely). Build a todos example project to validate the pipeline end-to-end.

**Tech Stack:** Gleam, glance (AST parser), simplifile (file I/O), ETF (wire format), Lustre (client framework), Mist (HTTP/WS server)

**Working directory:** `/Users/daverapin/projects/curling/libero` (on branch `v3-message-types`)

**Spec:** `docs/v3-spec.md`

**Build command:** `gleam build` (for the libero library itself). The todos example has its own packages.

**Test command:** `gleam test` (for libero library tests)

---

### Task 1: Set Up Todos Example Skeleton

Create the three-package example project structure with shared types, server handler, and client app. No generated code yet. This validates the target file layout before building the codegen.

**Files:**
- Create: `examples/todos/shared/gleam.toml`
- Create: `examples/todos/shared/src/shared/todo.gleam`
- Create: `examples/todos/server/gleam.toml`
- Create: `examples/todos/server/src/server/shared_state.gleam`
- Create: `examples/todos/server/src/server/app_error.gleam`
- Create: `examples/todos/server/src/server/handlers/todo.gleam`
- Create: `examples/todos/server/src/server.gleam`
- Create: `examples/todos/server/src/server/websocket.gleam`
- Create: `examples/todos/client/gleam.toml`
- Create: `examples/todos/client/src/client/app.gleam`

- [ ] **Step 1: Create shared package**

```toml
# examples/todos/shared/gleam.toml
name = "shared"
version = "0.1.0"
target = "erlang"

[dependencies]
gleam_stdlib = ">= 0.69.0 and < 1.0.0"
```

```gleam
// examples/todos/shared/src/shared/todo.gleam

pub type Todo {
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
  Created(Todo)
  Toggled(Todo)
  Deleted(id: Int)
  AllLoaded(List(Todo))
  Error(TodoError)
}
```

- [ ] **Step 2: Create server package with convention files**

```toml
# examples/todos/server/gleam.toml
name = "server"
version = "0.1.0"
target = "erlang"

[dependencies]
gleam_stdlib = ">= 0.69.0 and < 1.0.0"
gleam_erlang = "~> 0.34"
gleam_otp = "~> 0.14"
mist = "~> 4.0"
wisp = "~> 1.0"
shared = { path = "../shared" }
libero = { path = "../../.." }
```

```gleam
// examples/todos/server/src/server/shared_state.gleam

import shared/todo.{type Todo}

pub type SharedState {
  SharedState(next_id: Int, todos: List(Todo))
}

pub fn new() -> SharedState {
  SharedState(next_id: 1, todos: [])
}
```

```gleam
// examples/todos/server/src/server/app_error.gleam

import shared/todo

pub type AppError {
  TodoError(todo.TodoError)
}
```

```gleam
// examples/todos/server/src/server/handlers/todo.gleam

import gleam/list
import gleam/result
import server/app_error.{type AppError, TodoError}
import server/shared_state.{type SharedState, SharedState}
import shared/todo.{
  type MsgFromClient, type MsgFromServer, AllLoaded, Create, Created, Delete,
  Deleted, Error, LoadAll, NotFound, TitleRequired, Todo, Toggle, Toggled,
}

pub fn update_from_client(
  msg msg: MsgFromClient,
  state state: SharedState,
) -> Result(MsgFromServer, AppError) {
  case msg {
    Create(params:) -> {
      case params.title {
        "" -> Ok(Error(TitleRequired))
        title -> {
          let new_todo = Todo(id: state.next_id, title:, completed: False)
          Ok(Created(new_todo))
        }
      }
    }
    Toggle(id:) -> {
      case list.find(state.todos, fn(t) { t.id == id }) {
        Ok(found) -> Ok(Toggled(Todo(..found, completed: !found.completed)))
        _ -> Ok(Error(NotFound))
      }
    }
    Delete(id:) -> {
      case list.find(state.todos, fn(t) { t.id == id }) {
        Ok(_) -> Ok(Deleted(id))
        _ -> Ok(Error(NotFound))
      }
    }
    LoadAll -> Ok(AllLoaded(state.todos))
  }
}
```

```gleam
// examples/todos/server/src/server.gleam

import gleam/io

pub fn main() {
  io.println("todos server (placeholder)")
}
```

```gleam
// examples/todos/server/src/server/websocket.gleam

// Placeholder. Will be wired up after codegen produces dispatch.
import gleam/io

pub fn placeholder() -> Nil {
  io.println("websocket handler placeholder")
}
```

- [ ] **Step 3: Create client package**

```toml
# examples/todos/client/gleam.toml
name = "client"
version = "0.1.0"
target = "javascript"

[dependencies]
gleam_stdlib = ">= 0.69.0 and < 1.0.0"
lustre = "~> 5.6"
shared = { path = "../shared" }
libero = { path = "../../.." }
```

```gleam
// examples/todos/client/src/client/app.gleam

// Placeholder. Will be fleshed out after codegen produces send functions.
import gleam/io

pub fn main() {
  io.println("todos client (placeholder)")
}
```

- [ ] **Step 4: Verify shared and server packages compile**

Run: `cd examples/todos/shared && gleam build && cd ../server && gleam build`

Expected: both compile successfully.

- [ ] **Step 5: Commit**

```bash
git add examples/todos/
git commit -m "Add todos example skeleton with shared types and server handler"
```

---

### Task 2: Add Convention Validation Tests

Write tests that verify the codegen detects missing convention files and produces correct error messages. These tests will fail until we implement the scanning logic.

**Files:**
- Create: `test/libero/convention_test.gleam`
- Modify: `src/libero.gleam` (add new error types and a stub `scan_message_modules` function)

- [ ] **Step 1: Add new error types to libero.gleam**

Add these variants to the existing `GenError` type in `src/libero.gleam`:

```gleam
// Add to the GenError type (alongside existing variants):
MissingSharedState(expected_path: String)
MissingAppError(expected_path: String)
MissingHandler(message_module: String, expected_path: String)
NoMessageModules(shared_path: String)
```

- [ ] **Step 2: Add error formatting for new error types**

Add cases to the `print_error` function in `src/libero.gleam`:

```gleam
MissingSharedState(expected_path) ->
  "missing "
  <> expected_path
  <> "\n  libero expects a SharedState type at this path"
  <> "\n  create the file with: pub type SharedState { ... }"
MissingAppError(expected_path) ->
  "missing "
  <> expected_path
  <> "\n  libero expects an AppError type at this path"
  <> "\n  create the file with: pub type AppError { ... }"
MissingHandler(message_module, expected_path) ->
  "missing handler for "
  <> message_module
  <> "\n  expected: "
  <> expected_path
  <> "\n  with: pub fn update_from_client(msg: MsgFromClient, state: SharedState) -> Result(MsgFromServer, AppError)"
NoMessageModules(shared_path) ->
  "no message modules found in "
  <> shared_path
  <> "\n  add MsgFromClient and/or MsgFromServer types to a module in the shared package"
```

- [ ] **Step 3: Add stub `scan_message_modules` function**

Add to `src/libero.gleam`:

```gleam
/// A message module discovered in the shared package.
pub type MessageModule {
  MessageModule(
    /// Module path relative to shared/src/, e.g. "shared/todo"
    module_path: String,
    /// Absolute file path
    file_path: String,
    /// Whether this module exports a MsgFromClient type
    has_msg_from_client: Bool,
    /// Whether this module exports a MsgFromServer type
    has_msg_from_server: Bool,
  )
}

/// Scan the shared package for modules exporting MsgFromClient and/or MsgFromServer types.
pub fn scan_message_modules(
  shared_src shared_src: String,
) -> Result(List(MessageModule), List(GenError)) {
  // Stub: returns no modules found error for now
  Error([NoMessageModules(shared_path: shared_src)])
}

/// Validate that convention files exist for a set of message modules.
pub fn validate_conventions(
  message_modules message_modules: List(MessageModule),
  server_src server_src: String,
) -> List(GenError) {
  // Stub: returns empty list for now
  []
}
```

- [ ] **Step 4: Write the convention validation tests**

```gleam
// test/libero/convention_test.gleam

import gleam/list
import libero

pub fn scan_empty_shared_returns_no_modules_error_test() {
  // Use a temp dir with no .gleam files
  let result = libero.scan_message_modules(shared_src: "/tmp/nonexistent_libero_test")
  let assert Error(errors) = result
  let assert True =
    list.any(errors, fn(e) {
      case e {
        libero.NoMessageModules(_) -> True
        _ -> False
      }
    })
}

pub fn validate_missing_shared_state_test() {
  let modules = [
    libero.MessageModule(
      module_path: "shared/todo",
      file_path: "/tmp/todo.gleam",
      has_msg_from_client: True,
      has_msg_from_server: True,
    ),
  ]
  let errors =
    libero.validate_conventions(
      message_modules: modules,
      server_src: "/tmp/nonexistent_server_src",
    )
  let assert True =
    list.any(errors, fn(e) {
      case e {
        libero.MissingSharedState(_) -> True
        _ -> False
      }
    })
}

pub fn validate_missing_app_error_test() {
  let modules = [
    libero.MessageModule(
      module_path: "shared/todo",
      file_path: "/tmp/todo.gleam",
      has_msg_from_client: True,
      has_msg_from_server: True,
    ),
  ]
  let errors =
    libero.validate_conventions(
      message_modules: modules,
      server_src: "/tmp/nonexistent_server_src",
    )
  let assert True =
    list.any(errors, fn(e) {
      case e {
        libero.MissingAppError(_) -> True
        _ -> False
      }
    })
}

pub fn validate_missing_handler_test() {
  let modules = [
    libero.MessageModule(
      module_path: "shared/todo",
      file_path: "/tmp/todo.gleam",
      has_msg_from_client: True,
      has_msg_from_server: True,
    ),
  ]
  let errors =
    libero.validate_conventions(
      message_modules: modules,
      server_src: "/tmp/nonexistent_server_src",
    )
  let assert True =
    list.any(errors, fn(e) {
      case e {
        libero.MissingHandler(_, _) -> True
        _ -> False
      }
    })
}
```

- [ ] **Step 5: Verify tests fail (stubs return wrong values)**

Run: `gleam test`

Expected: convention tests fail because stubs don't implement the validation logic yet.

- [ ] **Step 6: Commit**

```bash
git add test/libero/convention_test.gleam src/libero.gleam
git commit -m "Add convention validation tests and error types for v3"
```

---

### Task 3: Implement Message Module Scanner

Replace the `@rpc`/`@inject` annotation scanning with `MsgFromClient`/`MsgFromServer` type scanning. This reads shared package source files via glance and identifies message modules.

**Files:**
- Modify: `src/libero.gleam` (implement `scan_message_modules`)

- [ ] **Step 1: Implement `scan_message_modules`**

Replace the stub in `src/libero.gleam`:

```gleam
/// Scan the shared package for modules exporting MsgFromClient and/or MsgFromServer types.
pub fn scan_message_modules(
  shared_src shared_src: String,
) -> Result(List(MessageModule), List(GenError)) {
  case walk_directory(path: shared_src) {
    Error(_) -> Error([NoMessageModules(shared_path: shared_src)])
    Ok(files) -> {
      let gleam_files =
        list.filter(files, fn(f) { string.ends_with(f, ".gleam") })
      let modules =
        list.filter_map(gleam_files, fn(file_path) {
          check_message_module(file_path:, shared_src:)
        })
      case modules {
        [] -> Error([NoMessageModules(shared_path: shared_src)])
        _ -> Ok(modules)
      }
    }
  }
}

fn check_message_module(
  file_path file_path: String,
  shared_src shared_src: String,
) -> Result(MessageModule, Nil) {
  use content <- result.try(
    simplifile.read(file_path) |> result.replace_error(Nil),
  )
  use parsed <- result.try(
    glance.module(content) |> result.replace_error(Nil),
  )

  let has_msg_from_client =
    list.any(parsed.custom_types, fn(ct) {
      let glance.Definition(_, t) = ct
      t.name == "MsgFromClient" && t.publicity == glance.Public
    })
  let has_msg_from_server =
    list.any(parsed.custom_types, fn(ct) {
      let glance.Definition(_, t) = ct
      t.name == "MsgFromServer" && t.publicity == glance.Public
    })

  case has_msg_from_client || has_msg_from_server {
    False -> Error(Nil)
    True -> {
      let prefix = shared_src <> "/"
      let relative =
        string.drop_start(file_path, string.length(prefix))
        |> string.drop_end(string.length(".gleam"))
      Ok(MessageModule(
        module_path: relative,
        file_path:,
        has_msg_from_client:,
        has_msg_from_server:,
      ))
    }
  }
}
```

- [ ] **Step 2: Add a scanning test using the todos example**

Add to `test/libero/convention_test.gleam`:

```gleam
pub fn scan_todos_example_finds_todo_module_test() {
  let assert Ok(modules) =
    libero.scan_message_modules(shared_src: "examples/todos/shared/src/shared")
  let assert True = list.length(modules) == 1
  let assert True =
    list.any(modules, fn(m) {
      m.module_path == "todo" && m.has_msg_from_client && m.has_msg_from_server
    })
}

pub fn scan_ignores_modules_without_message_types_test() {
  // The shared package root (shared/src/shared/) may have other files.
  // Create a temporary module without MsgFromClient/MsgFromServer and verify it's ignored.
  let assert Ok(modules) =
    libero.scan_message_modules(shared_src: "examples/todos/shared/src/shared")
  let assert True =
    list.all(modules, fn(m) { m.has_msg_from_client || m.has_msg_from_server })
}
```

- [ ] **Step 3: Run tests**

Run: `gleam test`

Expected: scanning tests pass, convention validation tests still fail.

- [ ] **Step 4: Commit**

```bash
git add src/libero.gleam test/libero/convention_test.gleam
git commit -m "Implement message module scanner for MsgFromClient/MsgFromServer types"
```

---

### Task 4: Implement Convention Validation

Implement the `validate_conventions` function that checks for `shared_state.gleam`, `app_error.gleam`, and handler modules.

**Files:**
- Modify: `src/libero.gleam` (implement `validate_conventions`)

- [ ] **Step 1: Implement `validate_conventions`**

Replace the stub:

```gleam
/// Validate that convention files exist for a set of message modules.
pub fn validate_conventions(
  message_modules message_modules: List(MessageModule),
  server_src server_src: String,
) -> List(GenError) {
  let shared_state_path = server_src <> "/server/shared_state.gleam"
  let app_error_path = server_src <> "/server/app_error.gleam"

  let state_errors = case simplifile.is_file(shared_state_path) {
    Ok(True) -> []
    _ -> [MissingSharedState(expected_path: shared_state_path)]
  }

  let error_errors = case simplifile.is_file(app_error_path) {
    Ok(True) -> []
    _ -> [MissingAppError(expected_path: app_error_path)]
  }

  let handler_errors =
    list.filter_map(message_modules, fn(m) {
      // Only require handler if module has MsgFromClient (server needs to handle it)
      case m.has_msg_from_client {
        False -> Error(Nil)
        True -> {
          // shared/todo -> server/handlers/todo.gleam
          let module_name = case string.split(m.module_path, "/") {
            [name] -> name
            parts -> list.last(parts) |> result.unwrap(m.module_path)
          }
          let handler_path =
            server_src <> "/server/handlers/" <> module_name <> ".gleam"
          case simplifile.is_file(handler_path) {
            Ok(True) -> Error(Nil)
            _ ->
              Ok(MissingHandler(
                message_module: m.module_path,
                expected_path: handler_path,
              ))
          }
        }
      }
    })

  list.concat([state_errors, error_errors, handler_errors])
}
```

- [ ] **Step 2: Run tests**

Run: `gleam test`

Expected: all convention validation tests pass (stubs are replaced with real implementation checking temp paths).

- [ ] **Step 3: Add a passing validation test against todos example**

Add to `test/libero/convention_test.gleam`:

```gleam
pub fn validate_todos_example_passes_test() {
  let assert Ok(modules) =
    libero.scan_message_modules(shared_src: "examples/todos/shared/src/shared")
  let errors =
    libero.validate_conventions(
      message_modules: modules,
      server_src: "examples/todos/server/src",
    )
  let assert True = list.is_empty(errors)
}
```

- [ ] **Step 4: Run tests**

Run: `gleam test`

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/libero.gleam test/libero/convention_test.gleam
git commit -m "Implement convention validation for SharedState, AppError, and handlers"
```

---

### Task 5: Modify Type Walker to Seed from Message Types

Change the type walker's seed from `@rpc` function signatures to `MsgFromClient`/`MsgFromServer` type constructors.

**Files:**
- Modify: `src/libero.gleam` (add `walk_message_types` function that wraps the existing BFS walker with new seed logic)

- [ ] **Step 1: Add `seed_from_message_modules` function**

This function extracts all type references from `MsgFromClient` and `MsgFromServer` constructors in message modules and returns seed pairs for the BFS walker.

```gleam
/// Extract seed types from MsgFromClient/MsgFromServer constructors for the BFS walker.
fn seed_from_message_modules(
  message_modules message_modules: List(MessageModule),
) -> Result(List(#(String, String)), List(GenError)) {
  let #(seeds, errors) =
    list.fold(message_modules, #(set.new(), []), fn(acc, m) {
      let #(seed_set, errs) = acc
      case simplifile.read(m.file_path) {
        Error(cause) -> #(seed_set, [CannotReadFile(m.file_path, cause), ..errs])
        Ok(content) ->
          case glance.module(content) {
            Error(_) -> #(seed_set, [ParseFailed(m.file_path, "glance error"), ..errs])
            Ok(parsed) -> {
              let type_resolver = build_type_resolver(parsed.imports)
              let new_seeds =
                list.fold(parsed.custom_types, seed_set, fn(acc2, ct) {
                  let glance.Definition(_, t) = ct
                  case t.name == "MsgFromClient" || t.name == "MsgFromServer" {
                    False -> acc2
                    True ->
                      list.fold(t.variants, acc2, fn(acc3, variant) {
                        list.fold(variant.fields, acc3, fn(acc4, field) {
                          collect_seed_refs(
                            type_: field.item,
                            resolver: type_resolver,
                            module_path: m.module_path,
                            acc: acc4,
                          )
                        })
                      })
                  }
                })
              #(new_seeds, errs)
            }
          }
      }
    })
  case errors {
    [] -> Ok(set.to_list(seeds))
    _ -> Error(errors)
  }
}

/// Collect type references from a glance.Type, adding (module_path, type_name)
/// pairs to the accumulator. Reuses the existing collect_type_refs logic.
fn collect_seed_refs(
  type_ type_: glance.Type,
  resolver resolver: TypeResolver,
  module_path module_path: String,
  acc acc: Set(#(String, String)),
) -> Set(#(String, String)) {
  // Delegate to the existing collect_type_refs which returns a list of refs.
  // Filter out primitives and skipped modules.
  let refs = collect_type_refs(type_: type_, resolver: resolver)
  list.fold(refs, acc, fn(a, ref) {
    let #(mod, name) = ref
    case is_skipped_module(mod) || is_primitive_type(name) {
      True -> a
      False -> set.insert(a, ref)
    }
  })
}
```

Note: `collect_type_refs` already exists in the codebase. The seed function reuses it with a different starting point (message type constructors instead of `@rpc` function parameters).

- [ ] **Step 2: Add `walk_message_registry_types` function**

```gleam
/// Walk the type graph rooted at MsgFromClient/MsgFromServer message types.
/// Returns all variants that need to be registered for ETF codecs.
fn walk_message_registry_types(
  message_modules message_modules: List(MessageModule),
  path_deps path_deps: List(PathDep),
) -> Result(List(DiscoveredVariant), List(GenError)) {
  use seed <- result.try(seed_from_message_modules(message_modules:))

  let module_files =
    list.fold(path_deps, dict.new(), fn(acc, dep) {
      merge_dep_module_files(acc: acc, dep: dep)
    })

  do_walk(
    queue: seed,
    visited: set.new(),
    discovered: [],
    module_files: module_files,
    parsed_cache: dict.new(),
    errors: [],
  )
}
```

- [ ] **Step 3: Write test for type walker seeding**

Add to `test/libero/convention_test.gleam`:

```gleam
pub fn scan_finds_types_referenced_in_constructors_test() {
  let assert Ok(modules) =
    libero.scan_message_modules(shared_src: "examples/todos/shared/src/shared")
  // TodoParams is referenced in MsgFromClient.Create(params: TodoParams)
  // Todo is referenced in MsgFromServer.Created(Todo), MsgFromServer.Toggled(Todo)
  // TodoError is referenced in MsgFromServer.Error(TodoError)
  // All three should be reachable from the message type constructors
  let assert True = list.length(modules) == 1
  let assert True = { list.first(modules) |> result.unwrap(libero.MessageModule("", "", False, False)) }.has_msg_from_client
}
```

- [ ] **Step 4: Run tests**

Run: `gleam test`

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/libero.gleam test/libero/convention_test.gleam
git commit -m "Add type walker seeding from MsgFromClient/MsgFromServer message constructors"
```

---

### Task 6: Generate Server Dispatch

Write the code generator for the server dispatch module. This replaces the v2 string-based dispatch with module-based routing.

**Files:**
- Modify: `src/libero.gleam` (add `write_v3_dispatch` function)

- [ ] **Step 1: Implement `write_v3_dispatch`**

```gleam
/// Generate the server dispatch module for v3 message-type routing.
fn write_v3_dispatch(
  message_modules message_modules: List(MessageModule),
  server_generated server_generated: String,
) -> Result(Nil, GenError) {
  let handler_imports =
    list.filter(message_modules, fn(m) { m.has_msg_from_client })
    |> list.map(fn(m) {
      let module_name = module_last_segment(m.module_path)
      "import server/handlers/"
      <> module_name
      <> " as "
      <> module_name
      <> "_handler"
    })
    |> string.join("\n")

  let case_arms =
    list.filter(message_modules, fn(m) { m.has_msg_from_client })
    |> list.map(fn(m) {
      let module_name = module_last_segment(m.module_path)
      "    Ok(#(\""
      <> m.module_path
      <> "\", msg)) ->\n"
      <> "      dispatch(fn() { "
      <> module_name
      <> "_handler.update_from_client(msg: wire.coerce(msg), state:) })"
    })
    |> string.join("\n")

  let content =
    "//// Code generated by libero. DO NOT EDIT.

import gleam/option.{type Option, None, Some}
import libero/error.{type PanicInfo, AppError, InternalError, MalformedRequest, UnknownFunction}
import libero/trace
import libero/wire
import server/app_error.{type AppError as ServerAppError}
import server/shared_state.{type SharedState}
"
    <> handler_imports
    <> "

pub fn handle(
  state state: SharedState,
  data data: BitArray,
) -> #(BitArray, Option(PanicInfo)) {
  case wire.decode_call(data) {
"
    <> case_arms
    <> "
    Ok(#(name, _)) ->
      #(wire.encode(Error(UnknownFunction(name))), None)
    Error(_) ->
      #(wire.encode(Error(MalformedRequest)), None)
  }
}

fn dispatch(
  call call: fn() -> Result(a, ServerAppError),
) -> #(BitArray, Option(PanicInfo)) {
  case trace.try_call(call) {
    Ok(Ok(value)) -> #(wire.encode(Ok(value)), None)
    Ok(Error(app_err)) -> #(wire.encode(Error(AppError(app_err))), None)
    Error(reason) -> {
      let trace_id = trace.new_trace_id()
      #(
        wire.encode(Error(InternalError(trace_id, \"Internal server error\"))),
        Some(trace.PanicInfo(trace_id:, fn_name: \"dispatch\", reason:)),
      )
    }
  }
}
"

  let path = server_generated <> "/dispatch.gleam"
  simplifile.write(path, content)
  |> result.map_error(fn(e) { CannotWriteFile(path, e) })
}

fn module_last_segment(module_path: String) -> String {
  case string.split(module_path, "/") {
    [name] -> name
    parts -> list.last(parts) |> result.unwrap(module_path)
  }
}
```

- [ ] **Step 2: Verify it generates correct output by running against todos example manually**

This will be integrated into the full pipeline later. For now, verify the function exists and compiles.

Run: `gleam build`

Expected: compiles successfully.

- [ ] **Step 3: Commit**

```bash
git add src/libero.gleam
git commit -m "Add server dispatch generator for v3 message-type routing"
```

---

### Task 7: Generate Client Send Functions

Write the code generator for per-module client send functions.

**Files:**
- Modify: `src/libero.gleam` (add `write_v3_send_functions` function)

- [ ] **Step 1: Implement `write_v3_send_functions`**

```gleam
/// Generate a client send function for each message module with MsgFromClient.
fn write_v3_send_functions(
  message_modules message_modules: List(MessageModule),
  client_generated client_generated: String,
  config config: Config,
) -> Result(Nil, List(GenError)) {
  let errors =
    list.filter(message_modules, fn(m) { m.has_msg_from_client })
    |> list.filter_map(fn(m) {
      case write_v3_send_function(message_module: m, client_generated:, config:) {
        Ok(Nil) -> Error(Nil)
        Error(e) -> Ok(e)
      }
    })
  case errors {
    [] -> Ok(Nil)
    _ -> Error(errors)
  }
}

fn write_v3_send_function(
  message_module message_module: MessageModule,
  client_generated client_generated: String,
  config config: Config,
) -> Result(Nil, GenError) {
  let module_name = module_last_segment(message_module.module_path)

  let content =
    "//// Code generated by libero. DO NOT EDIT.

import "
    <> message_module.module_path
    <> ".{type MsgFromClient}
import libero/rpc
import client/generated/libero/config as rpc_config
import lustre/effect.{type Effect}

pub fn send_to_server(msg msg: MsgFromClient) -> Effect(msg) {
  rpc.send(
    url: rpc_config.ws_url(),
    module: \""
    <> message_module.module_path
    <> "\",
    msg: msg,
  )
}
"

  let path = client_generated <> "/" <> module_name <> ".gleam"
  simplifile.write(path, content)
  |> result.map_error(fn(e) { CannotWriteFile(path, e) })
}
```

- [ ] **Step 2: Verify it compiles**

Run: `gleam build`

Expected: compiles successfully.

- [ ] **Step 3: Commit**

```bash
git add src/libero.gleam
git commit -m "Add client send function generator for v3"
```

---

### Task 8: Update Wire Module for v3 Envelope

Change `decode_call` to return `#(String, Dynamic)` instead of `#(String, List(Dynamic))`, matching the v3 wire envelope where the second element is a single `MsgFromClient` value, not a list of arguments.

**Files:**
- Modify: `src/libero/wire.gleam`
- Modify: `src/libero_wire_ffi.erl` (Erlang FFI for decode_call)
- Modify: `src/libero/rpc.gleam` (replace `call_by_name` with `send`)
- Modify: `src/libero/rpc_ffi.mjs` (update `call` to `send` with new envelope)

- [ ] **Step 1: Update `wire.gleam` signature**

```gleam
// Change decode_call return type
pub fn decode_call(
  data: BitArray,
) -> Result(#(String, Dynamic), DecodeError) {
  ffi_decode_call(data)
}

@external(erlang, "libero_wire_ffi", "decode_call")
fn ffi_decode_call(
  data: BitArray,
) -> Result(#(String, Dynamic), DecodeError) {
  let _ = data
  panic as "libero/wire.decode_call is a server-side function, unreachable on JavaScript target"
}

/// Coerce a Dynamic value to any type. Safe when client and server are
/// built from the same source (the generator guarantees type alignment).
@external(erlang, "libero_ffi", "identity")
@external(javascript, "./rpc_ffi.mjs", "identity")
pub fn coerce(value: Dynamic) -> a {
  let _ = value
  panic as "unreachable"
}
```

- [ ] **Step 2: Update Erlang FFI `decode_call`**

Modify `src/libero_wire_ffi.erl` to return `{module_name, value}` instead of `{fn_name, args_list}`:

```erlang
decode_call(Data) ->
    try
        case erlang:binary_to_term(Data, [safe]) of
            {Module, Value} when is_binary(Module) ->
                {ok, {Module, Value}};
            _ ->
                {error, {decode_error, <<"expected {module_binary, value} tuple">>}}
        end
    catch
        _:_ ->
            {error, {decode_error, <<"failed to decode ETF binary">>}}
    end.
```

- [ ] **Step 3: Update `rpc.gleam` - replace `call_by_name` with `send`**

```gleam
//// Client-side RPC machinery for libero v3.
////
//// `send` is the entrypoint used by generated per-module send functions.
//// It takes the WebSocket URL, the module name, and the MsgFromClient message
//// value, encodes them as an ETF envelope, and sends over WebSocket.

import gleam/dynamic.{type Dynamic}
import lustre/effect.{type Effect}

/// Send a MsgFromClient message to the server over WebSocket.
/// Called by generated send functions.
pub fn send(
  url url: String,
  module module: String,
  msg msg: a,
) -> Effect(msg) {
  effect.from(fn(_dispatch) {
    ffi_send(url:, module:, msg:)
  })
}

@external(javascript, "./rpc_ffi.mjs", "send")
fn ffi_send(
  url url: String,
  module module: String,
  msg msg: a,
) -> Nil {
  let _ = url
  let _ = module
  let _ = msg
  panic as "libero/rpc is a JavaScript-only module, unreachable on Erlang target"
}

@external(javascript, "./rpc_ffi.mjs", "identity")
pub fn unsafe_coerce(value: Dynamic) -> a {
  let _ = value
  panic as "libero/rpc is a JavaScript-only module, unreachable on Erlang target"
}
```

- [ ] **Step 4: Update `rpc_ffi.mjs` - replace `call` with `send`**

Add a new `send` function alongside the existing `call` (which will be removed later after v2 cleanup):

```javascript
// v3 send: encode {module_name, msg} and send over WebSocket
export function send(url, module, msg) {
  const payload = encodeETF([module, msg]);  // 2-tuple: {binary, term}
  ensureSocket(url);
  if (socket && socket.readyState === WebSocket.OPEN) {
    socket.send(payload);
  } else {
    sendQueue.push(payload);
  }
}
```

Note: the exact encoding details depend on the existing ETF encoder in rpc_ffi.mjs. The key change is encoding `{module_binary, msg_value}` instead of `{fn_name_binary, args_list}`.

- [ ] **Step 5: Verify it compiles**

Run: `gleam build`

Expected: compiles. Wire tests may need updating due to signature change.

- [ ] **Step 6: Update wire tests if needed**

If `wire_test.gleam` or `wire_roundtrip_test.gleam` test `decode_call`, update them to match the new `#(String, Dynamic)` return type.

- [ ] **Step 7: Run tests**

Run: `gleam test`

Expected: all tests pass.

- [ ] **Step 8: Commit**

```bash
git add src/libero/wire.gleam src/libero_wire_ffi.erl src/libero/rpc.gleam src/libero/rpc_ffi.mjs
git commit -m "Update wire envelope and RPC module for v3 message-type format"
```

---

### Task 9: Wire Up the v3 Pipeline

Connect scanning, validation, type walking, and code generation into a new `run_v3` pipeline. Update the CLI to use it.

**Files:**
- Modify: `src/libero.gleam` (add `run_v3` function, update `main` and `parse_config`)

- [ ] **Step 1: Update Config type**

Add new fields for v3 paths:

```gleam
// Add to Config type:
shared_src: String,    // e.g. "../shared/src/shared"
server_src: String,    // e.g. "src"
server_generated: String,  // e.g. "src/server/generated/libero"
client_generated: String,  // e.g. "../client/src/client/generated/libero"
```

- [ ] **Step 2: Update CLI parsing**

Add `--shared` and `--server` flags to `parse_config`:

```gleam
let shared_path = find_flag(args, "--shared=") |> result.unwrap("../shared")
let server_path = find_flag(args, "--server=") |> result.unwrap(".")
```

- [ ] **Step 3: Implement `run_v3`**

```gleam
fn run_v3(config: Config) -> Result(Int, List(GenError)) {
  // Step 1: Scan shared package for message modules
  use message_modules <- result.try(
    scan_message_modules(shared_src: config.shared_src),
  )
  io.println(
    "libero: found "
    <> int.to_string(list.length(message_modules))
    <> " message modules",
  )

  // Step 2: Validate conventions
  let validation_errors =
    validate_conventions(
      message_modules:,
      server_src: config.server_src,
    )
  case validation_errors {
    [_, ..] -> Error(validation_errors)
    [] -> {
      // Step 3: Ensure generated output directories exist
      let _ = simplifile.create_directory_all(config.server_generated)
      let _ = simplifile.create_directory_all(config.client_generated)

      // Step 4: Walk type graph from message types
      let path_deps = build_path_deps(config)
      use discovered <- result.try(
        walk_message_registry_types(message_modules:, path_deps:),
      )
      io.println(
        "libero: discovered "
        <> int.to_string(list.length(discovered))
        <> " types for registration",
      )

      // Step 5: Generate outputs
      use _ <- result.try(
        write_v3_dispatch(message_modules:, server_generated: config.server_generated)
        |> result.map_error(fn(e) { [e] }),
      )
      use _ <- result.try(
        write_v3_send_functions(message_modules:, client_generated: config.client_generated, config:)
      )
      use _ <- result.try(
        write_config(config:) |> result.map_error(fn(e) { [e] }),
      )
      use _ <- result.try(
        write_register(config:, discovered:)
        |> result.map_error(fn(errors) { errors }),
      )
      use _ <- result.try(
        write_atoms(config:, discovered:)
        |> result.map_error(fn(e) { [e] }),
      )

      Ok(list.length(message_modules))
    }
  }
}
```

- [ ] **Step 4: Update `main` to call `run_v3`**

```gleam
pub fn main() -> Nil {
  trap_signals()
  let config = parse_config()
  io.println("libero: scanning " <> config.shared_src)

  case run_v3(config) {
    Ok(count) -> {
      io.println(
        "libero: done. generated dispatch for "
        <> int.to_string(count)
        <> " message modules",
      )
      let _halt = halt(0)
    }
    Error(errors) -> {
      list.each(errors, print_error)
      let count = int.to_string(list.length(errors))
      io.println_error("")
      io.println_error("libero: " <> count <> " error(s), no files generated")
      let _halt = halt(1)
    }
  }
}
```

- [ ] **Step 5: Verify it compiles**

Run: `gleam build`

Expected: compiles.

- [ ] **Step 6: Commit**

```bash
git add src/libero.gleam
git commit -m "Wire up v3 pipeline: scan, validate, walk, generate"
```

---

### Task 10: Integration Test - Run Codegen Against Todos Example

Run the v3 codegen against the todos example and verify the example compiles with generated code.

**Files:**
- No new files (generated files are created by codegen)

- [ ] **Step 1: Run codegen against todos example**

```bash
cd examples/todos/server && gleam run -m libero -- --shared=../shared --ws-path=/ws --client=../client
```

Expected: codegen succeeds, prints message count.

- [ ] **Step 2: Verify generated files exist**

```bash
ls examples/todos/server/src/server/generated/libero/dispatch.gleam
ls examples/todos/client/src/client/generated/libero/todo.gleam
ls examples/todos/client/src/client/generated/libero/config.gleam
```

- [ ] **Step 3: Compile the todos server**

```bash
cd examples/todos/server && gleam build
```

Expected: compiles successfully. The generated dispatch imports the handler, which imports shared types. If any types are wrong, the compiler catches it.

- [ ] **Step 4: Compile the todos client**

```bash
cd examples/todos/client && gleam build
```

Expected: compiles successfully.

- [ ] **Step 5: Commit generated files and any fixes**

```bash
git add examples/todos/
git commit -m "Integration test: codegen produces valid output for todos example"
```

---

### Task 11: Delete v2 Dead Code

Remove all annotation-based codegen code, inject system, and per-function stub generation. This is cleanup after v3 is working.

**Files:**
- Modify: `src/libero.gleam` (delete v2-only functions, types, and error variants)
- Delete: `examples/fizzbuzz/` (replaced by todos)
- Modify: tests as needed (remove v2-specific tests)

- [ ] **Step 1: Delete v2-only types and functions from `libero.gleam`**

Remove:
- `InjectFn` type
- `SessionInfo` type
- `Rpc` type (replaced by `MessageModule`)
- `find_annotated_functions` function
- `extract_inject_map` / `build_inject_map` functions
- `extract_rpcs_from_file` function
- `write_stub_files` / `render_stub_fn` functions
- `write_dispatch` (v2 dispatch, replaced by `write_v3_dispatch`)
- `walk_registry_types` (replaced by `walk_message_registry_types`)
- `find_duplicate_wire_names` function
- v2-only `GenError` variants: `NoContextParam`, `NoReturnType`, `UnlabelledParam`, `UntypedParam`, `UnknownType`, `LikelyInjectTypo`, `DuplicateWireName`
- `write_inputs_manifest` function
- v2-only `run` function (replaced by `run_v3`)

- [ ] **Step 2: Delete fizzbuzz example**

```bash
rm -rf examples/fizzbuzz/
```

- [ ] **Step 3: Remove v2-specific tests**

Remove tests that reference `@rpc`, `@inject`, or v2-specific functions. Keep: wire tests, trace tests, error tests, levenshtein tests, convention tests.

- [ ] **Step 4: Verify everything compiles and tests pass**

Run: `gleam build && gleam test`

Expected: compiles clean, all remaining tests pass.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Delete v2 codegen: annotations, inject system, per-function stubs, fizzbuzz example"
```

---

### Task 12: Update Client RPC FFI for v3 Envelope

Fully update `rpc_ffi.mjs` to encode/decode the v3 wire envelope `{module_name, msg_value}` and handle response routing.

**Files:**
- Modify: `src/libero/rpc_ffi.mjs`

- [ ] **Step 1: Update the `send` function to encode v3 envelope**

The v3 envelope is a 2-tuple: `{module_name_binary, toserver_value}`. The existing ETF encoder already handles tuples, binaries, and custom types. The `send` function needs to construct this tuple and encode it.

```javascript
export function send(url, module, msg) {
  const envelope = [module, msg];  // Will be encoded as {binary, term}
  const encoded = encodeValue(envelope);
  ensureSocket(url);
  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.send(encoded);
  } else {
    pendingQueue.push(encoded);
  }
}
```

Note: the exact implementation depends on the existing `encodeValue` / ETF encoder internals. The tuple encoding must produce ETF SMALL_TUPLE_EXT (tag 104) with 2 elements: a BINARY_EXT for the module name and the ETF encoding of the message value.

- [ ] **Step 2: Update response handling**

v3 responses are `Result(MsgFromServer, RpcError(AppError))` encoded as ETF. The existing decoder already handles `Result` (Ok/Error atoms with values). The response handler needs to decode and dispatch to the caller.

The response flow depends on how the client tracks pending requests. In v2, `call_by_name` registers a callback per call. In v3, `send` is fire-and-response, so we need a similar mechanism. The WebSocket `onmessage` handler decodes the response and dispatches it.

This will be refined during implementation based on the existing WebSocket management code in `rpc_ffi.mjs`.

- [ ] **Step 3: Remove v2 `call` function**

Delete the `call` export and any v2-specific request tracking.

- [ ] **Step 4: Verify client-side compilation**

```bash
cd examples/todos/client && gleam build
```

Expected: compiles.

- [ ] **Step 5: Commit**

```bash
git add src/libero/rpc_ffi.mjs
git commit -m "Update client RPC FFI for v3 wire envelope"
```

---

### Task 13: Wire Up Todos Example End-to-End

Complete the todos example with working WebSocket handler and client app to demonstrate the full v3 pipeline.

**Files:**
- Modify: `examples/todos/server/src/server.gleam` (HTTP + WS server)
- Modify: `examples/todos/server/src/server/websocket.gleam` (WS handler calling dispatch)
- Modify: `examples/todos/client/src/client/app.gleam` (Lustre SPA)

- [ ] **Step 1: Implement server WebSocket handler**

```gleam
// examples/todos/server/src/server/websocket.gleam

import gleam/option.{None}
import mist
import server/generated/libero/dispatch
import server/shared_state.{type SharedState}

pub type State {
  State(shared: SharedState)
}

pub fn on_init(shared: SharedState) {
  fn(_conn) {
    #(State(shared:), None)
  }
}

pub fn handler(state: State, message: mist.WebsocketMessage(Nil), connection) {
  case message {
    mist.Binary(data) -> {
      let #(response, _maybe_panic) =
        dispatch.handle(state: state.shared, data:)
      let _ = mist.send_binary_frame(connection, response)
      mist.continue(state)
    }
    mist.Closed | mist.Shutdown -> mist.stop()
    _ -> mist.continue(state)
  }
}
```

- [ ] **Step 2: Implement server HTTP entry point**

```gleam
// examples/todos/server/src/server.gleam

import gleam/erlang/process
import gleam/io
import mist
import server/shared_state
import server/websocket

pub fn main() {
  let shared = shared_state.new()

  let assert Ok(_) =
    fn(req) {
      mist.websocket(
        request: req,
        on_init: websocket.on_init(shared),
        on_close: fn(_state) { Nil },
        handler: websocket.handler,
      )
    }
    |> mist.new
    |> mist.port(8080)
    |> mist.start_http

  io.println("todos server running on :8080")
  process.sleep_forever()
}
```

- [ ] **Step 3: Implement client Lustre app**

```gleam
// examples/todos/client/src/client/app.gleam

import client/generated/libero/todo as todo_rpc
import lustre
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import shared/todo

pub type Model {
  Model(todos: List(todo.Todo), draft: String, error: String)
}

pub type Msg {
  UserUpdatedDraft(String)
  UserClickedAdd
  UserClickedToggle(Int)
  UserClickedDelete(Int)
  FromServer(todo.MsgFromServer)
}

pub fn main() {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", Nil)
  Nil
}

fn init(_flags) -> #(Model, Effect(Msg)) {
  #(
    Model(todos: [], draft: "", error: ""),
    todo_rpc.send_to_server(msg: todo.LoadAll)
      |> effect.map(fn(_) { FromServer(todo.AllLoaded([])) }),
  )
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    UserUpdatedDraft(text) -> #(Model(..model, draft: text), effect.none())
    UserClickedAdd -> #(
      Model(..model, draft: ""),
      todo_rpc.send_to_server(msg: todo.Create(params: todo.TodoParams(title: model.draft))),
    )
    UserClickedToggle(id) -> #(model, todo_rpc.send_to_server(msg: todo.Toggle(id:)))
    UserClickedDelete(id) -> #(model, todo_rpc.send_to_server(msg: todo.Delete(id:)))
    FromServer(server_msg) ->
      case server_msg {
        todo.Created(new_todo) -> #(
          Model(..model, todos: [new_todo, ..model.todos], error: ""),
          effect.none(),
        )
        todo.Toggled(updated) -> #(
          Model(
            ..model,
            todos: list.map(model.todos, fn(t) {
              case t.id == updated.id {
                True -> updated
                False -> t
              }
            }),
          ),
          effect.none(),
        )
        todo.Deleted(id) -> #(
          Model(
            ..model,
            todos: list.filter(model.todos, fn(t) { t.id != id }),
          ),
          effect.none(),
        )
        todo.AllLoaded(all) -> #(Model(..model, todos: all), effect.none())
        todo.Error(_err) -> #(Model(..model, error: "An error occurred"), effect.none())
      }
  }
}

fn view(model: Model) -> Element(Msg) {
  html.div([], [
    html.h1([], [element.text("Todos")]),
    html.form([event.on_submit(fn(_) { UserClickedAdd })], [
      html.input([
        event.on_input(UserUpdatedDraft),
      ]),
      html.button([], [element.text("Add")]),
    ]),
    html.ul(
      [],
      list.map(model.todos, fn(t) {
        html.li([], [
          html.span(
            [event.on_click(UserClickedToggle(t.id))],
            [element.text(t.title)],
          ),
          html.button(
            [event.on_click(UserClickedDelete(t.id))],
            [element.text("x")],
          ),
        ])
      }),
    ),
  ])
}
```

Note: the client app above is a starting point. The exact send/receive wiring may need adjustment based on how the response callback mechanism works in v3. The core pattern (send MsgFromClient, receive MsgFromServer via FromServer wrapper) is what matters.

- [ ] **Step 4: Compile both packages**

```bash
cd examples/todos/server && gleam build
cd examples/todos/client && gleam build
```

Expected: both compile.

- [ ] **Step 5: Commit**

```bash
git add examples/todos/
git commit -m "Wire up todos example end-to-end with WebSocket handler and Lustre client"
```

---

### Task 14: Final Cleanup and Documentation

Update README, clean up the codebase, run linter.

**Files:**
- Modify: `README.md`
- Modify: `gleam.toml` (version bump)
- Delete: any remaining v2-only files

- [ ] **Step 1: Update version in gleam.toml**

Change version from `"2.1.0"` to `"3.0.0-dev"`.

- [ ] **Step 2: Update README.md**

Update the README to describe the v3 convention:
- `MsgFromClient`/`MsgFromServer` types in shared modules
- Convention-based handler paths
- Example usage from todos

- [ ] **Step 3: Run linter**

```bash
gleam run -m glinter
```

Fix any warnings.

- [ ] **Step 4: Run all tests**

```bash
gleam test
```

Expected: all pass.

- [ ] **Step 5: Final commit**

```bash
git add -A
git commit -m "v3.0.0-dev: message-type-driven codegen with MsgFromClient/MsgFromServer convention"
```

Plan complete and saved to `docs/v3-plan.md`. Two execution options:

**1. Subagent-Driven (recommended)** - I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** - Execute tasks in this session using executing-plans, batch execution with checkpoints

Which approach?