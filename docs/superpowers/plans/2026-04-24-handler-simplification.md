# Handler API Simplification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Simplify handler return from `Result(#(MsgFromServer, SharedState), AppError)` to `#(MsgFromServer, SharedState)` by dropping AppError, removing the outer Result, and adding scanner-based per-variant routing so multi-handler chains don't need UnhandledMessage.

**Architecture:** The scanner parses handler case arms to learn which MsgFromClient variants each handler responds to. Codegen generates direct per-variant routing instead of chaining. AppError is removed from the handler convention and from RpcError. Dispatch catches panics (as before) but no longer unwraps an outer Result.

**Tech Stack:** Gleam (scanner, codegen, error, remote_data), Erlang (no changes), JavaScript (rpc_ffi.mjs), glance (AST parsing)

---

## File map

| File | Action | Responsibility |
|------|--------|---------------|
| `src/libero/scanner.gleam` | Modify | Add `handled_variants` field to DiscoveredHandler; parse case arms in update_from_client body |
| `src/libero/codegen.gleam` | Modify | Generate per-variant routing for multi-handler; remove AppError from dispatch/safe_encode; handler closure returns `#(a, SharedState)` not `Result` |
| `src/libero/error.gleam` | Modify | Remove `AppError(e)` variant from RpcError; remove `Never` type (no longer needed) |
| `src/libero/remote_data.gleam` | Modify | Remove AppError case from `format_rpc_error` |
| `src/libero/rpc_ffi.mjs` | Modify | Remove `"app_error"` case from `decodeRpcError` |
| `src/libero/gen_error.gleam` | Modify | Update MissingHandler hint to show new handler signature |
| `src/libero/cli/templates.gleam` | Modify | Update starter_handler, starter_app_error, starter_test templates |
| `src/libero/ssr.gleam` | No change | SSR call uses raw dispatch, unaffected |
| `examples/todos/src/server/handler.gleam` | Modify | Remove `Result`/`Ok` wrapping, remove AppError import |
| `examples/todos/src/server/app_error.gleam` | Delete | No longer needed |
| `examples/todos/test/todos_test.gleam` | Modify | Remove `Ok` from assertions |
| `test/libero/multi_handler_dispatch_test.gleam` | Modify | Update assertions for per-variant routing |
| `test/libero/codegen_test.gleam` | Modify | Update dispatch snapshot assertions |
| `test/libero/remote_data_test.gleam` | No change | No AppError tests exist |
| `llms.txt` | Modify | Update handler signature and dispatch docs |
| `README.md` | Modify | Update handler example |

---

### Task 1: Scanner - extract handled variants from case arms

**Files:**
- Modify: `src/libero/scanner.gleam:42-51` (DiscoveredHandler type), `src/libero/scanner.gleam:140-171` (parse_handler function)

- [ ] **Step 1: Add handled_variants field to DiscoveredHandler**

```gleam
type DiscoveredHandler {
  DiscoveredHandler(
    handler_module: String,
    shared_module: String,
    /// MsgFromClient variant names this handler matches, e.g. ["LoadAll", "Create"]
    /// Empty list means the scanner couldn't determine (fallback to chaining)
    handled_variants: List(String),
  )
}
```

- [ ] **Step 2: Write the variant extraction function**

Add a new function `extract_handled_variants` that walks the function body to find case arm patterns:

```gleam
/// Extract MsgFromClient variant names from the case arms in update_from_client.
/// Walks the function body looking for a Case expression on `msg`, then collects
/// PatternVariant constructor names from each clause. Ignores discard/variable
/// patterns (catch-all arms like `_ -> ...`).
fn extract_handled_variants(func: glance.Function) -> List(String) {
  // Walk statements to find the case expression
  list.flat_map(func.body, fn(stmt) {
    case stmt {
      glance.Expression(glance.Case(subjects: _, clauses:, ..)) ->
        extract_variant_names(clauses)
      _ -> []
    }
  })
}

/// Extract constructor names from case clause patterns.
fn extract_variant_names(clauses: List(glance.Clause)) -> List(String) {
  list.flat_map(clauses, fn(clause) {
    list.flat_map(clause.patterns, fn(pattern_list) {
      list.filter_map(pattern_list, fn(pattern) {
        case pattern {
          glance.PatternVariant(constructor: name, ..) -> Ok(name)
          _ -> Error(Nil)
        }
      })
    })
  })
}
```

- [ ] **Step 3: Call extract_handled_variants in parse_handler**

Update `parse_handler` to call `extract_handled_variants` and include the result in `DiscoveredHandler`. After the line `use glance.Definition(_, func) <- result.try(target)` (line 157), the function already has `func`. Pass it through:

```gleam
  let handler_module = derive_module_path(file_path: file_path)
  let handled_variants = extract_handled_variants(func)
  Ok(DiscoveredHandler(
    handler_module: handler_module,
    shared_module: shared_module,
    handled_variants: handled_variants,
  ))
```

- [ ] **Step 4: Run `gleam check` to verify compilation**

Run: `gleam check`
Expected: Compiles (DiscoveredHandler is a private type, only used internally by scanner).

- [ ] **Step 5: Commit**

```
git add src/libero/scanner.gleam
git commit -m "Scanner: extract handled variant names from handler case arms"
```

---

### Task 2: Thread handled_variants through to codegen

**Files:**
- Modify: `src/libero/scanner.gleam:26-39` (MessageModule type)
- Modify: `src/libero/scanner.gleam` (where handler_modules is populated)
- Modify: `src/libero/codegen.gleam:30-36` (write_dispatch signature)

The MessageModule type currently stores `handler_modules: List(String)`. We need to also carry the variant mapping. Change to a list of handler info tuples.

- [ ] **Step 1: Add HandlerInfo type to scanner and update MessageModule**

```gleam
/// A handler module and the MsgFromClient variants it handles.
pub type HandlerInfo {
  HandlerInfo(
    module_path: String,
    handled_variants: List(String),
  )
}

pub type MessageModule {
  MessageModule(
    module_path: String,
    file_path: String,
    has_msg_from_client: Bool,
    has_msg_from_server: Bool,
    /// Handler modules and their variant mappings.
    handlers: List(HandlerInfo),
  )
}
```

- [ ] **Step 2: Update all references from `handler_modules` to `handlers`**

Search scanner.gleam for `handler_modules` and update each occurrence to build `HandlerInfo` values instead of bare strings. The key site is where `DiscoveredHandler` results are collected and assigned to `MessageModule`. Also update the check in `scanner.gleam` that validates handlers exist (around line 360-370).

Update codegen.gleam: everywhere that reads `m.handler_modules` needs to read `m.handlers` and extract `handler.module_path`. The `write_dispatch` function signature loses the `app_error_module` parameter (AppError is being removed).

- [ ] **Step 3: Update codegen write_dispatch signature**

Remove `app_error_module` parameter:

```gleam
pub fn write_dispatch(
  message_modules message_modules: List(MessageModule),
  server_generated server_generated: String,
  atoms_module atoms_module: String,
  shared_state_module shared_state_module: String,
) -> Result(Nil, GenError) {
```

- [ ] **Step 4: Update cli/gen.gleam call site**

Remove the `app_error_module` argument from the `write_dispatch` call.

- [ ] **Step 5: Update test call sites**

Update `test/libero/multi_handler_dispatch_test.gleam` and `test/libero/codegen_test.gleam` to use the new `MessageModule` shape with `handlers: [HandlerInfo(...)]` instead of `handler_modules: [...]`, and remove `app_error_module` from `write_dispatch` calls.

- [ ] **Step 6: Run `gleam check`**

Expected: Compiles. Tests may fail (codegen output changed) but compilation succeeds.

- [ ] **Step 7: Commit**

```
git add src/libero/scanner.gleam src/libero/codegen.gleam src/libero/cli/gen.gleam test/
git commit -m "Thread handled_variants from scanner through to codegen"
```

---

### Task 3: Generate per-variant routing in dispatch

**Files:**
- Modify: `src/libero/codegen.gleam:64-212`
- Modify: `test/libero/multi_handler_dispatch_test.gleam`

- [ ] **Step 1: Rewrite multi-handler case arm generation**

Replace the chaining logic with per-variant routing. For a module with handlers A (LoadThemes, DeleteTheme) and B (LoadDashboard):

Generate:
```gleam
    Ok(#("shared/messages", request_id, msg)) -> {
      let typed_msg: shared_messages_msg.MsgFromClient = wire.coerce(msg)
      case typed_msg {
        shared_messages_msg.LoadThemes(..) | shared_messages_msg.DeleteTheme(..) ->
          dispatch(state, request_id, fn() { handler_a.update_from_client(msg: typed_msg, state:) })
        shared_messages_msg.LoadDashboard(..) ->
          dispatch(state, request_id, fn() { handler_b.update_from_client(msg: typed_msg, state:) })
      }
    }
```

Each handler's variants become a `|`-separated pattern. Each variant uses `(..)` spread to match regardless of fields.

- [ ] **Step 2: Update dispatch function template to remove AppError**

Change the closure type and remove the AppError unwrap:

```gleam
fn dispatch(
  state state: SharedState,
  request_id request_id: Int,
  call call: fn() -> #(a, SharedState),
) -> #(BitArray, Option(PanicInfo), SharedState) {
  case trace.try_call(call) {
    Ok(#(value, new_state)) ->
      safe_encode(fn() { wire.encode(Ok(value)) }, new_state, request_id, \"dispatch_encode_ok\")
    Error(reason) -> {
      let trace_id = trace.new_trace_id()
      #(
        wire.tag_response(request_id:, data: wire.encode(Error(InternalError(trace_id, \"Internal server error\")))),
        Some(error.PanicInfo(trace_id:, fn_name: \"dispatch\", reason:)),
        state,
      )
    }
  }
}
```

Key changes: closure returns `#(a, SharedState)` not `Result`. Pattern match is `Ok(#(value, new_state))` not `Ok(Ok(#(...)))`. The `Ok(Error(app_err))` arm is deleted.

- [ ] **Step 3: Remove AppError import from generated dispatch**

Remove the `app_error` import line and the `needs_unhandled_import` logic entirely. The generated dispatch no longer references AppError or UnhandledMessage.

- [ ] **Step 4: Keep single-handler path simple**

Single-handler modules still generate the same simple arm (no case-within-case needed):

```gleam
    Ok(#("shared/messages", request_id, msg)) ->
      dispatch(state, request_id, fn() { handler.update_from_client(msg: wire.coerce(msg), state:) })
```

- [ ] **Step 5: Update multi_handler_dispatch_test**

Replace UnhandledMessage/chaining assertions with per-variant routing assertions:

```gleam
pub fn multi_handler_dispatch_chains_test() {
  // ... setup with HandlerInfo ...
  
  // Must NOT import UnhandledMessage (no longer used)
  let assert False = string.contains(content, "UnhandledMessage")
  
  // Must route per-variant to correct handler
  let assert True = string.contains(content, "case typed_msg {")
  let assert True = string.contains(content, "server_handler_a_handler.update_from_client")
  let assert True = string.contains(content, "server_handler_b_handler.update_from_client")
}
```

- [ ] **Step 6: Run tests**

Run: `gleam test`
Expected: All pass.

- [ ] **Step 7: Commit**

```
git add src/libero/codegen.gleam test/
git commit -m "Generate per-variant dispatch routing, drop AppError from dispatch"
```

---

### Task 4: Remove AppError from error.gleam and client-side code

**Files:**
- Modify: `src/libero/error.gleam:36-73`
- Modify: `src/libero/remote_data.gleam:145-150`
- Modify: `src/libero/rpc_ffi.mjs:882-902`

- [ ] **Step 1: Remove AppError variant from RpcError**

In `src/libero/error.gleam`, remove the `AppError(e)` variant and the `Never` type. RpcError becomes non-generic:

```gleam
pub type RpcError {
  MalformedRequest
  UnknownFunction(name: String)
  InternalError(trace_id: String, message: String)
}
```

Remove the `Never` type and its documentation (lines 36-39). Update the module docs to reflect that domain errors only travel inside MsgFromServer variant payloads.

- [ ] **Step 2: Update remote_data.gleam**

In `format_rpc_error`, delete the `error.AppError(_)` case. Update the `from_response` function: the outer coerce type changes from `Result(Dynamic, RpcError(app))` to `Result(Dynamic, RpcError)`:

```gleam
  let outer: Result(Dynamic, RpcError) = wire.coerce(raw)
```

The `format_domain` parameter can stay for now (it still formats domain errors inside the peeled MsgFromServer variant).

- [ ] **Step 3: Update rpc_ffi.mjs**

In the `decodeRpcError` function, delete the `case "app_error"` arm:

```javascript
function decodeRpcError(term) {
  if (term === "malformed_request") return new MalformedRequest();
  if (!Array.isArray(term)) {
    return new InternalError("", "Malformed RpcError: " + String(term));
  }
  switch (term[0]) {
    case "malformed_request": return new MalformedRequest();
    case "unknown_function": return new UnknownFunction(term[1]);
    case "internal_error": return new InternalError(term[1], term[2]);
    default:
      return new InternalError("", "Unknown RpcError variant: " + String(term[0]));
  }
}
```

Also search for `AppError` class definition/registration in rpc_ffi.mjs and remove it.

- [ ] **Step 4: Run tests**

Run: `gleam test`
Expected: All pass (AppError was never actually sent on the wire in tests).

- [ ] **Step 5: Commit**

```
git add src/libero/error.gleam src/libero/remote_data.gleam src/libero/rpc_ffi.mjs
git commit -m "Remove AppError from RpcError and client-side decoding"
```

---

### Task 5: Update examples and templates

**Files:**
- Modify: `examples/todos/src/server/handler.gleam`
- Delete: `examples/todos/src/server/app_error.gleam`
- Modify: `examples/todos/test/todos_test.gleam`
- Modify: `src/libero/cli/templates.gleam`
- Modify: `src/libero/gen_error.gleam:83-94`

- [ ] **Step 1: Update todos handler**

Remove Result/Ok wrapping, remove AppError import:

```gleam
import ets_store
import server/shared_state.{type SharedState}
import shared/messages.{
  type MsgFromClient, type MsgFromServer, Create, Delete, LoadAll, NotFound,
  TitleRequired, Todo, TodoCreated, TodoDeleted, TodoToggled, TodosLoaded,
  Toggle,
}

pub fn update_from_client(
  msg msg: MsgFromClient,
  state state: SharedState,
) -> #(MsgFromServer, SharedState) {
  case msg {
    Create(params:) ->
      case params.title {
        "" -> #(TodoCreated(Error(TitleRequired)), state)
        title -> {
          let id = ets_store.next_id()
          let item = Todo(id:, title:, completed: False)
          ets_store.insert(id, item)
          #(TodoCreated(Ok(item)), state)
        }
      }
    Toggle(id:) ->
      case ets_store.lookup(id) {
        Error(Nil) -> #(TodoToggled(Error(NotFound)), state)
        Ok(item) -> {
          let toggled = Todo(..item, completed: !item.completed)
          ets_store.insert(id, toggled)
          #(TodoToggled(Ok(toggled)), state)
        }
      }
    Delete(id:) ->
      case ets_store.lookup(id) {
        Error(Nil) -> #(TodoDeleted(Error(NotFound)), state)
        Ok(_) -> {
          ets_store.delete(id)
          #(TodoDeleted(Ok(id)), state)
        }
      }
    LoadAll -> #(TodosLoaded(Ok(ets_store.all())), state)
  }
}
```

- [ ] **Step 2: Delete todos app_error.gleam**

```bash
rm examples/todos/src/server/app_error.gleam
```

- [ ] **Step 3: Update todos test**

Remove `Ok(#(...))` and change to `#(...)`:

```gleam
pub fn create_with_empty_title_returns_error_test() {
  let state = fresh_state()
  let assert #(TodoCreated(Error(messages.TitleRequired)), _) =
    handler.update_from_client(
      msg: Create(params: TodoParams(title: "")),
      state:,
    )
}

pub fn create_returns_todo_with_id_test() {
  let state = fresh_state()
  let assert #(
    TodoCreated(Ok(Todo(id: _, title: "Buy milk", completed: False))),
    _,
  ) =
    handler.update_from_client(
      msg: Create(params: TodoParams(title: "Buy milk")),
      state:,
    )
}
```

Apply the same pattern to all test functions: remove `Ok(` prefix and matching `)`.

- [ ] **Step 4: Update starter templates**

In `src/libero/cli/templates.gleam`:

Update `starter_handler`:
```gleam
pub fn starter_handler() -> String {
  "import server/shared_state.{type SharedState}
import shared/messages.{type MsgFromClient, type MsgFromServer, Ping, Pong}

pub fn update_from_client(
  msg msg: MsgFromClient,
  state state: SharedState,
) -> #(MsgFromServer, SharedState) {
  case msg {
    Ping -> #(Pong(Ok(\"pong\")), state)
  }
}
"
}
```

Update `starter_app_error` to return a minimal file (or remove it if codegen no longer generates the import). If the scaffold still creates it, make it empty or a placeholder for domain errors only.

Update `starter_test`:
```gleam
pub fn starter_test() -> String {
  "import server/handler
import server/shared_state
import shared/messages.{Ping, Pong}
import gleeunit

pub fn main() {
  gleeunit.main()
}

pub fn ping_test() {
  let state = shared_state.new()
  let assert #(Pong(Ok(\"pong\")), _) =
    handler.update_from_client(msg: Ping, state:)
}
"
}
```

- [ ] **Step 5: Update gen_error.gleam hint**

Update the MissingHandler hint (line 89-94):

```gleam
    MissingHandler(message_module, expected) -> "error: Missing handler module
  \u{250c}\u{2500} " <> expected <> ".gleam
  \u{2502}
  \u{2502} Message module `" <> message_module <> "` has MsgFromClient
  \u{2502} but no handler was found at `" <> expected <> "`
  \u{2502}
  hint: Create the handler module:
        // " <> expected <> ".gleam
        pub fn update_from_client(
          msg msg: MsgFromClient,
          state state: SharedState,
        ) -> #(MsgFromServer, SharedState)"
```

- [ ] **Step 6: Run `gleam run -m libero -- build` in todos example**

```bash
cd examples/todos && gleam run -m libero -- build
```

Expected: Builds clean.

- [ ] **Step 7: Run todos tests**

```bash
cd examples/todos && gleam test
```

Expected: All pass.

- [ ] **Step 8: Commit**

```
git add examples/ src/libero/cli/templates.gleam src/libero/gen_error.gleam
git commit -m "Update examples and templates for simplified handler signature"
```

---

### Task 6: Update docs

**Files:**
- Modify: `README.md`
- Modify: `llms.txt`

- [ ] **Step 1: Update README handler example**

Replace the handler section with the new signature:

```gleam
pub fn update_from_client(
  msg msg: MsgFromClient,
  state state: SharedState,
) -> #(MsgFromServer, SharedState) {
  case msg {
    messages.LoadAll -> #(TodosLoaded(Ok(all())), state)
    messages.Create(params:) -> #(TodoCreated(Ok(insert(params.title))), state)
    // ...
  }
}
```

- [ ] **Step 2: Update llms.txt handler section**

Update the server handler example and key patterns to reflect the new signature. Remove references to AppError.

- [ ] **Step 3: Update error model section in llms.txt**

The error model changes from three tiers to two:
1. **Domain errors** - inside MsgFromServer variant: `Result(payload, DomainError)`
2. **Framework errors** - `MalformedRequest`, `UnknownFunction(name)`, `InternalError(trace_id, message)`

AppError tier is removed.

- [ ] **Step 4: Check for em dashes**

Run: `grep -n '\xe2\x80\x94' README.md llms.txt`
Expected: No matches.

- [ ] **Step 5: Run format and lint**

```bash
gleam format src/ test/ examples/
gleam run -m glinter
```

- [ ] **Step 6: Commit**

```
git add README.md llms.txt
git commit -m "Update docs for simplified handler API"
```

---

### Task 7: Version bump and final verification

**Files:**
- Modify: `gleam.toml`

- [ ] **Step 1: Bump version**

This is another breaking change on top of v5.0.0. Bump to `5.1.0` (minor, since v5 hasn't been published to hex yet and this is additive from the user's perspective) or stay at `5.0.0` if we haven't published.

Check: has 5.0.0 been published to hex? If not, keep 5.0.0. If yes, bump to 6.0.0.

- [ ] **Step 2: Full test suite**

```bash
gleam test
```

Expected: All pass.

- [ ] **Step 3: Build todos example end-to-end**

```bash
cd examples/todos && gleam run -m libero -- build && gleam test
```

- [ ] **Step 4: Build ssr_hydration example**

```bash
cd examples/ssr_hydration && gleam run -m libero -- build
```

- [ ] **Step 5: Commit and push**

```bash
git add gleam.toml
git commit -m "Final verification for handler simplification"
git push
```
