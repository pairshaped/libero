# Libero v3 Spec: Message-Type-Driven Codegen

## Goal

Replace annotation-based codegen (`@rpc`, `@inject`) with a message-type convention. The entire framework surface is two type names: `MsgFromClient` and `MsgFromServer`. Modules in `shared/` that export these types define the wire contract. The codegen generates dispatch, send functions, and wire codecs from these types.

## Conventions

### Message modules

Any module in the shared package that exports a `MsgFromClient` and/or `MsgFromServer` type is a message module. The codegen scans `shared/src/` recursively and identifies these modules via glance AST parsing.

File organization is up to the developer. One file with all messages, split by domain, split by direction: all valid. The type names are the convention, not the file layout.

```
// One file:
shared/src/shared/
  message.gleam

// By domain:
shared/src/shared/
  todo.gleam
  account.gleam
```

### Handler modules

For each message module, a corresponding handler must exist on the server. The path is conventional:

- Message module: `shared/src/shared/todo.gleam`
- Handler module: `server/src/server/handlers/todo.gleam`

Handler signature:

```gleam
pub fn update_from_client(
  msg msg: todo.MsgFromClient,
  state state: SharedState,
) -> Result(todo.MsgFromServer, AppError)
```

The handler is NOT generated. The developer writes it. The generated dispatch imports and calls it.

### SharedState and AppError conventions

Defined by the developer at conventional paths:

- `server/src/server/shared_state.gleam` exporting `pub type SharedState`
- `server/src/server/app_error.gleam` exporting `pub type AppError`

The codegen verifies these files exist and export the expected types before generating dispatch code. Missing files produce clear error messages.

## Codegen pipeline

### CLI interface

```
libero --shared=../shared --server=../server --client=../client --ws-path=/ws
```

Flags:
- `--shared`: path to shared package (default: `../shared`)
- `--server`: path to server package (default: `../server`)
- `--client`: path to client package (default: `../client`)
- `--ws-url` or `--ws-path`: WebSocket URL configuration (one required, mutually exclusive)

Retained from v2: `--namespace` (optional, scopes generated output paths).
Removed from v2: `--write-inputs`.

### Pipeline steps

1. **Scan shared package**: recursively find all `.gleam` files in `shared/src/`, parse with glance, identify modules exporting `MsgFromClient` or `MsgFromServer` types.

2. **Validate conventions**: check that `server/shared_state.gleam` and `server/app_error.gleam` exist and export expected types. Check that a handler module exists for each message module.

3. **Walk type graph**: BFS from all types referenced in `MsgFromClient` and `MsgFromServer` constructors. Same algorithm as v2 (handles recursive types, caches parsed modules, detects float fields). Collect all reachable types for codec registration.

4. **Generate outputs**:
   - Server dispatch
   - Client send functions (one per message module)
   - Client receive dispatch (for `MsgFromServer` messages)
   - Wire codec registration (JS: registerConstructor FFI, Erlang: atoms file)
   - RPC config (ws_url)

5. **Report**: errors collected across all steps, reported together. Same error-accumulation pattern as v2.

## Wire envelope

### v2 Format

```
{fn_name_binary, [arg1, arg2, ...]}
```

String-based function name, flat argument list.

### v3 Format

```
{module_name_binary, msg_from_client_value}
```

Module name identifies the domain handler. The value is the full `MsgFromClient` union type instance (ETF-encoded with constructor atom tag), not a flat argument list.

Example: `todo.send_to_server(todo.Delete(id: 42))` sends:

```
{"shared/todo", Delete(42)}
```

### Response format

Same as v2: ETF-encoded `Result(MsgFromServer, RpcError(AppError))`.

- Success: `Ok(todo_msg_from_server_value)`
- App error: `Error(AppError(app_error_value))`
- Framework errors: `Error(MalformedRequest)`, `Error(UnknownFunction(name))`
- Panics: `Error(InternalError(trace_id, message))`

## Generated code

### Server dispatch

Output: `server/src/server/generated/libero/dispatch.gleam`

```gleam
import server/shared_state.{type SharedState}
import server/app_error.{type AppError}
import server/handlers/todo as todo_handler
import server/handlers/account as account_handler
import libero/wire
import libero/trace.{type PanicInfo}
import libero/error.{AppError, InternalError, MalformedRequest, UnknownFunction}

pub fn handle(
  state state: SharedState,
  data data: BitArray,
) -> #(BitArray, Option(PanicInfo)) {
  case wire.decode_call(data) {
    Ok(#("shared/todo", msg)) ->
      dispatch(fn() { todo_handler.update_from_client(msg: wire.coerce(msg), state:) })
    Ok(#("shared/account", msg)) ->
      dispatch(fn() { account_handler.update_from_client(msg: wire.coerce(msg), state:) })
    Ok(#(name, _)) ->
      #(wire.encode(Error(UnknownFunction(name))), None)
    Error(_) ->
      #(wire.encode(Error(MalformedRequest)), None)
  }
}

fn dispatch(
  call call: fn() -> Result(a, AppError),
) -> #(BitArray, Option(PanicInfo)) {
  case trace.try_call(call) {
    Ok(Ok(value)) -> #(wire.encode(Ok(value)), None)
    Ok(Error(app_err)) -> #(wire.encode(Error(AppError(app_err))), None)
    Error(reason) -> {
      let trace_id = trace.new_trace_id()
      #(
        wire.encode(Error(InternalError(trace_id, "Internal server error"))),
        Some(trace.PanicInfo(trace_id:, reason:)),
      )
    }
  }
}
```

### Client send functions

One generated file per message module.

Output: `client/src/client/generated/libero/todo.gleam`

```gleam
import shared/todo
import libero/rpc
import libero/rpc_config
import lustre/effect.{type Effect}

pub fn send_to_server(msg: todo.MsgFromClient) -> Effect(msg) {
  rpc.send(
    url: rpc_config.ws_url(),
    module: "shared/todo",
    msg: msg,
  )
}
```

Client usage:

```gleam
import shared/todo
import client/generated/libero/todo as todo_rpc

// In update:
todo_rpc.send_to_server(todo.Delete(id: 42))
```

### Client receive dispatch

Output: `client/src/client/generated/libero/receive.gleam`

Decodes incoming `MsgFromServer` messages from the server. Returns a tagged value so the client app can route to the correct domain handler.

```gleam
import shared/todo
import shared/account
import libero/wire
import libero/error.{type RpcError}

pub type ServerMessage {
  TodoMessage(Result(todo.MsgFromServer, RpcError(AppError)))
  AccountMessage(Result(account.MsgFromServer, RpcError(AppError)))
}

pub fn decode(data: BitArray) -> ServerMessage {
  case wire.decode_module(data) {
    #("shared/todo", payload) -> TodoMessage(wire.decode_result(payload))
    #("shared/account", payload) -> AccountMessage(wire.decode_result(payload))
  }
}
```

### Wire codec registration

Same structure as v2, different seed types.

**JS FFI** (`client/src/client/generated/libero/register_ffi.mjs`):
- Import constructor classes from shared package MJS output
- `registerConstructor("todo", _m0.Todo)` for each discovered variant (seeded from `MsgFromClient`/`MsgFromServer` constructors)
- `registerFloatFields(...)` for variants with Float fields

**Gleam wrapper** (`client/src/client/generated/libero/register.gleam`):
- `pub fn register_all() -> Nil` calling FFI

**Erlang atoms** (`server/src/server/generated/libero/atoms.erl`):
- Pre-register all constructor atoms with BEAM
- Framework atoms (ok, error, some, none, etc.)
- Called once per VM via persistent_term guard

### RPC config

Output: `client/src/client/generated/libero/config.gleam`

Same as v2. Single function exposing WebSocket URL:

```gleam
pub fn ws_url() -> String {
  "/ws"  // or runtime resolution from window.location for multi-tenant
}
```

## Changes to libero/rpc (client runtime)

The `rpc` module's `send` function takes a module name and a message value (instead of a wire name and an args tuple):

```gleam
pub fn send(
  url url: String,
  module module: String,
  msg msg: a,
) -> Effect(msg) {
  // ETF-encode as {module, msg}, send over WebSocket
}
```

The existing `call_by_name` function is removed.

## Changes to libero/wire

### decode_call (Server Side)

v2: `fn decode_call(data: BitArray) -> Result(#(String, List(Dynamic)), DecodeError)`

v3: `fn decode_call(data: BitArray) -> Result(#(String, Dynamic), DecodeError)`

Returns the module name and the raw `MsgFromClient` value as Dynamic (not a list of arguments). The dispatch coerces it to the correct type.

## Deleted code

- Annotation scanner (`find_annotated_functions`): line-based `@rpc`/`@inject` detection
- Inject system: `extract_inject_map`, inject function extraction, session type inference, label matching
- Per-function stub generation: `render_stub_fn`, `write_stub_files`
- String-based dispatch: wire name matching, per-function case arms with inject calls
- `call_by_name` in `libero/rpc`
- `--write-inputs` CLI handling

## Example project: todos

Three-package example replacing fizzbuzz.

### shared/src/shared/todo.gleam

```gleam
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

### server/src/server/shared_state.gleam

```gleam
pub type SharedState {
  SharedState(
    next_id: Int,
    todos: List(Todo),
  )
}
```

In-memory storage for simplicity. No database.

### server/src/server/app_error.gleam

```gleam
pub type AppError {
  TodoError(todo.TodoError)
}
```

### server/src/server/handlers/todo.gleam

```gleam
pub fn update_from_client(
  msg msg: todo.MsgFromClient,
  state state: SharedState,
) -> Result(todo.MsgFromServer, AppError) {
  case msg {
    todo.Create(params:) -> ...
    todo.Toggle(id:) -> ...
    todo.Delete(id:) -> ...
    todo.LoadAll -> ...
  }
}
```

### client/src/client/app.gleam

Lustre SPA with:
- Local `Msg` type wrapping `todo.MsgFromServer` via `FromServer` variant
- `update` handling local UI messages and server responses
- `view` rendering the todo list with add/toggle/delete controls

## Testing

### Kept from v2 (unchanged)

- `wire_test.gleam`: ETF encode/decode
- `wire_roundtrip_test.gleam`: full round-trips
- `trace_test.gleam`: panic catching
- `error_test.gleam`: error envelope
- `levenshtein_test.gleam`: typo detection (used for "did you mean?" on unknown modules)

### New tests

**Convention validation errors:**
- Missing `shared_state.gleam` produces correct error
- Missing `app_error.gleam` produces correct error
- Missing handler module for a message module produces correct error
- Error messages include expected file path and type signature

**Type scanning:**
- Module with `MsgFromClient` only is detected as message module
- Module with `MsgFromServer` only is detected as message module
- Module with both is detected
- Module with neither is ignored
- Types referenced in `MsgFromClient`/`MsgFromServer` constructors seed the type walker correctly

**Type walker (modified seed):**
- All types reachable from `MsgFromClient` constructors are discovered
- All types reachable from `MsgFromServer` constructors are discovered
- Recursive types handled (visited set prevents cycles)
- Float fields detected correctly

**Codegen integration:**
- Run codegen against todos example
- `gleam build` succeeds on the example (generated code is valid)
- Generated dispatch routes messages to correct handlers
- Generated send function produces correct wire envelope

### Deleted tests

- Annotation scanning tests
- Inject-related tests
- Input manifest tests
