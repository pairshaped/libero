//// Template strings for `libero new` scaffolding.
////
//// Each function returns a file's content as a String. The generated
//// files give a new project a minimal skeleton to build from.

/// Libero version constraint used in generated gleam.toml files.
/// Update this constant when bumping the libero version.
const libero_version = "~> 5.0"

/// Returns gleam.toml content for a new project (the server package).
/// Libero config lives under the [tools.libero] section.
/// `db_deps` is inserted after the existing deps (e.g. pog, sqlight lines).
/// `extra_toml` is appended after the [tools.libero] section (e.g. [tools.marmot]).
pub fn gleam_toml(
  name name: String,
  db_deps db_deps: String,
  extra_toml extra_toml: String,
) -> String {
  "name = \"" <> name <> "\"
version = \"0.1.0\"
target = \"erlang\"

[dependencies]
gleam_stdlib = \">= 0.69.0 and < 1.0.0\"
gleam_erlang = \"~> 1.0\"
gleam_http = \"~> 4.0\"
mist = \"~> 6.0\"
lustre = \"~> 5.6\"
shared = { path = \"shared\" }
libero = \"" <> libero_version <> "\"
" <> db_deps <> "
[dev-dependencies]
gleeunit = \"~> 1.0\"

[tools.libero]
port = 8080
" <> extra_toml
}

/// Returns gleam.toml content for the shared package.
/// Target-agnostic so both the Erlang server and JS clients can import
/// messages and types from it.
pub fn shared_gleam_toml() -> String {
  "name = \"shared\"
version = \"0.1.0\"

# No target specified - compiles to both Erlang and JavaScript.

[dependencies]
gleam_stdlib = \">= 0.69.0 and < 1.0.0\"
libero = \"" <> libero_version <> "\"

[dev-dependencies]
gleeunit = \"~> 1.0\"
"
}

/// Returns a skeleton shared types module.
///
/// Domain types used in handler signatures live here. Only types
/// exported from shared/ (or builtins) can appear in handler
/// function signatures. Libero scans these to validate endpoints.
pub fn starter_messages() -> String {
  "/// Domain types shared between server and client.
/// Only types from shared/ (or builtins like Int, String, List)
/// can appear in handler function signatures.

pub type PingError {
  PingFailed
}
"
}

/// Returns a skeleton handler module.
///
/// Each pub function becomes an RPC endpoint. Libero detects them
/// by checking: (1) public, (2) last param is HandlerContext,
/// (3) returns #(Result(value, error), HandlerContext), and
/// (4) all types come from shared/ or are builtins.
pub fn starter_handler() -> String {
  "import server/handler_context.{type HandlerContext}
import shared/messages.{type PingError}

pub fn ping(
  state state: HandlerContext,
) -> #(Result(String, PingError), HandlerContext) {
  #(Ok(\"pong\"), state)
}
"
}

/// Returns a skeleton HandlerContext module.
pub fn starter_context() -> String {
  "pub type HandlerContext {
  HandlerContext
}

pub fn new() -> HandlerContext {
  HandlerContext
}
"
}

/// Returns a skeleton test that verifies the handler works.
pub fn starter_test() -> String {
  "import server/handler
import server/handler_context
import gleeunit

pub fn main() {
  gleeunit.main()
}

pub fn ping_test() {
  let state = handler_context.new()
  let assert #(Ok(\"pong\"), _) =
    handler.ping(state:)
}
"
}

/// Returns a starter Lustre SPA app module with a working RPC example.
pub fn starter_spa(name name: String) -> String {
  "import generated/messages as rpc
import libero/remote_data.{
  type RemoteData, Failure, Loading, NotAsked, Success, TransportFailure,
}
import lustre
import lustre/element.{type Element}
import lustre/element/html
import lustre/effect.{type Effect}
import lustre/event
import shared/messages.{type PingError}

// -- Model --

pub type Model {
  Model(response: RemoteData(String, PingError))
}

// -- Messages --

pub type Msg {
  UserClickedPing
  GotPong(RemoteData(String, PingError))
}

// -- Init --

fn init(_flags) -> #(Model, Effect(Msg)) {
  #(Model(response: NotAsked), effect.none())
}

// -- Update --

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    UserClickedPing -> #(
      Model(response: Loading),
      rpc.ping(on_response: GotPong),
    )
    GotPong(rd) -> #(Model(response: rd), effect.none())
  }
}

// -- View --

fn view(model: Model) -> Element(Msg) {
  html.div([], [
    html.h1([], [html.text(\"" <> name <> "\")]),
    html.button([event.on_click(UserClickedPing)], [html.text(\"Ping\")]),
    html.p([], [html.text(
      case model.response {
        NotAsked -> \"Click the button to ping the server.\"
        Loading -> \"Loading...\"
        Success(msg) -> \"Server says: \" <> msg
        Failure(_err) -> \"Ping failed\"
        TransportFailure(message) -> \"Transport error: \" <> message
      },
    )]),
  ])
}

// -- Main --

pub fn main() {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, \"#app\", Nil)
  Nil
}
"
}

/// Returns a gleam.toml for a client package.
pub fn client_gleam_toml(
  name name: String,
  target target: String,
  root_package root_package: String,
) -> String {
  "name = \"" <> name <> "\"
version = \"0.1.0\"
target = \"" <> target <> "\"

[dependencies]
gleam_stdlib = \">= 0.69.0 and < 1.0.0\"
shared = { path = \"../../shared\" }
" <> root_package <> " = { path = \"../../\" }
libero = \"" <> libero_version <> "\"
" <> case target {
    "javascript" -> "lustre = \"~> 5.6\"\n"
    _ -> ""
  }
}

/// Returns a starter CLI main module.
pub fn starter_cli() -> String {
  "import gleam/io

pub fn main() -> Nil {
  io.println(\"Hello from your Libero app!\")
}
"
}

/// Returns a README.md for a new project.
/// `db_section` is optional database-specific content appended to the end.
pub fn starter_readme(
  name name: String,
  db_section db_section: String,
) -> String {
  "# " <> name <> "

A Libero project.

## Getting started

Build the generated client and server code, then start the server:

```sh
gleam run -m libero -- build
gleam run
```

The server starts on the port configured in `gleam.toml` under
`[tools.libero]` (default 8080).

## Project structure

```
src/server/         Server-side Gleam code (handlers, context, etc.)
shared/             Domain types shared between server and clients
clients/            Client packages (SPA, CLI, etc.)
test/               Tests
```

## Commands

- `gleam run -m libero -- build` generates dispatch, client stubs, and
  other derived code from your handler signatures.
- `gleam run -m libero -- gen` regenerates only the derived code without
  rebuilding everything.
- `gleam run -m libero -- add <name> --target <javascript|erlang>` adds
  a new client package.
- `gleam test` runs the test suite.

## How it works

Define your domain types in `shared/src/shared/messages.gleam`, then
write handler functions in `src/server/handler.gleam`. Each public
function that takes a `HandlerContext` as its last parameter and
returns `#(Result(value, error), HandlerContext)` becomes an RPC
endpoint.

When you run `libero build`, it scans those handler signatures and
generates:

- A `ClientMsg` type with a variant per handler function.
- A dispatch module that routes each variant to the right handler.
- Typed client stubs so each client package can call the server
  with typed arguments.

Server context (database connections, caches, etc.) is threaded through
`HandlerContext` so every handler call has access to it.
" <> db_section
}
