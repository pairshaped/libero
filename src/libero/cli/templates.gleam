//// Template strings for `libero new` scaffolding.
////
//// Each function returns a file's content as a String. The generated
//// files give a new project a minimal skeleton to build from.

/// Returns gleam.toml content for a new project.
/// Libero config lives under the [libero] section.
pub fn gleam_toml(name name: String) -> String {
  "name = \""
  <> name
  <> "\"
version = \"0.1.0\"
target = \"erlang\"

[dependencies]
gleam_stdlib = \">= 0.69.0 and < 1.0.0\"
lustre = \"~> 5.6\"
libero = { path = \"../libero\" }

[dev-dependencies]
gleeunit = \"~> 1.0\"

[libero]
port = 8080
"
}

/// Returns a skeleton messages module.
///
/// Defines the typed RPC boundary between client and server.
/// Add your message types here — libero scans for MsgFromClient
/// and MsgFromServer to generate dispatch and client stubs.
pub fn starter_messages() -> String {
  "/// Define your message types here.
/// Libero scans for MsgFromClient and MsgFromServer to generate
/// dispatch and client stubs.

pub type MsgFromClient {
  Ping
}

pub type MsgFromServer {
  Pong(String)
}
"
}

/// Returns a skeleton handler module.
pub fn starter_handler() -> String {
  "import core/app_error.{type AppError}
import core/messages.{type MsgFromClient, type MsgFromServer, Ping, Pong}
import core/shared_state.{type SharedState}

pub fn update_from_client(
  msg msg: MsgFromClient,
  state state: SharedState,
) -> Result(#(MsgFromServer, SharedState), AppError) {
  case msg {
    Ping -> Ok(#(Pong(\"pong\"), state))
  }
}
"
}

/// Returns a skeleton SharedState module.
pub fn starter_shared_state() -> String {
  "pub type SharedState {
  SharedState
}

pub fn new() -> SharedState {
  SharedState
}
"
}

/// Returns a skeleton AppError module.
pub fn starter_app_error() -> String {
  "pub type AppError {
  AppError(reason: String)
}
"
}

/// Returns a skeleton test that verifies the handler works.
pub fn starter_test() -> String {
  "import core/messages.{Ping, Pong}
import core/handler
import core/shared_state
import gleeunit

pub fn main() {
  gleeunit.main()
}

pub fn ping_test() {
  let state = shared_state.new()
  let assert Ok(#(Pong(\"pong\"), _)) =
    handler.update_from_client(msg: Ping, state:)
}
"
}

/// Returns a starter Lustre SPA app module.
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
    html.h1([], [html.text(\""
  <> name
  <> "\")]),
    html.p([], [html.text(\"Edit this file to get started.\")]),
  ])
}
"
}

/// Returns a gleam.toml for a client package.
pub fn client_gleam_toml(
  name name: String,
  target target: String,
  root_package root_package: String,
) -> String {
  "name = \""
  <> name
  <> "\"
version = \"0.1.0\"
target = \""
  <> target
  <> "\"

[dependencies]
gleam_stdlib = \">= 0.69.0 and < 1.0.0\"
"
  <> root_package
  <> " = { path = \"../../\" }
libero = { path = \"../../../libero\" }
"
  <> case target {
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
