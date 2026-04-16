//// Scanning and convention validation for message modules.
////
//// Discovers modules in the shared package that export `MsgFromClient` or
//// `MsgFromServer` custom types, and validates that the server package
//// follows the required conventions (handler modules, shared state, etc.).

import glance
import gleam/bool
import gleam/dict.{type Dict}
import gleam/list
import gleam/result
import gleam/string
import libero/gen_error.{
  type GenError, CannotReadDir, MissingAppError, MissingHandler,
  MissingSharedState, NoMessageModules,
}
import simplifile

// ---------- Types ----------

/// A message module discovered in the shared package.
pub type MessageModule {
  MessageModule(
    /// Module path relative to shared/src/, e.g. "shared/todos"
    module_path: String,
    /// Absolute file path
    file_path: String,
    /// Whether this module exports a MsgFromClient type
    has_msg_from_client: Bool,
    /// Whether this module exports a MsgFromServer type
    has_msg_from_server: Bool,
  )
}

// ---------- Message module scanner ----------

/// Scan the shared package source directory for modules that export
/// `MsgFromClient` or `MsgFromServer` types. These define the wire contract for
/// the message-type convention.
///
/// Returns `Ok(modules)` with the list of matching modules, or
/// `Error([NoMessageModules(...)])` if no message modules are found.
pub fn scan_message_modules(
  shared_src shared_src: String,
) -> Result(#(List(MessageModule), Dict(String, String)), List(GenError)) {
  let files =
    walk_directory(path: shared_src)
    |> result.map_error(fn(cause) { [cause, NoMessageModules(shared_path: shared_src)] })
  use files <- result.try(files)
  // Build module_files dict from all discovered .gleam files
  let module_files =
    list.fold(files, dict.new(), fn(acc, file_path) {
      let module_path = derive_module_path(file_path: file_path)
      dict.insert(acc, module_path, file_path)
    })
  let modules =
    list.filter_map(files, fn(file_path) {
      parse_message_module(file_path: file_path)
    })
  case modules {
    [] -> Error([NoMessageModules(shared_path: shared_src)])
    _ -> Ok(#(modules, module_files))
  }
}

fn parse_message_module(
  file_path file_path: String,
) -> Result(MessageModule, Nil) {
  use content <- result.try(
    simplifile.read(file_path)
    |> result.replace_error(Nil),
  )
  use parsed <- result.try(
    glance.module(content)
    |> result.replace_error(Nil),
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
  use <- bool.guard(
    when: !has_msg_from_client && !has_msg_from_server,
    return: Error(Nil),
  )
  let module_path = derive_module_path(file_path: file_path)
  Ok(MessageModule(
    module_path: module_path,
    file_path: file_path,
    has_msg_from_client: has_msg_from_client,
    has_msg_from_server: has_msg_from_server,
  ))
}

// ---------- Source discovery ----------

/// Recursively walk a directory, returning every `.gleam` file found.
/// Skips any subdirectory named `generated`, since libero never reads its
/// own output, and leaving this convention in place means consumers
/// don't need to configure scan_excludes as their projects grow.
fn walk_directory(path path: String) -> Result(List(String), GenError) {
  use entries <- result.try(
    simplifile.read_directory(path)
    |> result.map_error(fn(cause) { CannotReadDir(path: path, cause: cause) }),
  )
  list.try_fold(over: entries, from: [], with: fn(acc, entry) {
    visit_entry(acc: acc, parent: path, entry: entry)
  })
}

/// Classify a single directory entry and fold it into the accumulator.
/// Stat failures (permissions, races) fall through as "not a directory",
/// which means the entry is evaluated as a file and filtered out unless
/// its name happens to end in `.gleam`. Missing files can't match, so
/// silently skipping is safe.
fn visit_entry(
  acc acc: List(String),
  parent parent: String,
  entry entry: String,
) -> Result(List(String), GenError) {
  let child = parent <> "/" <> entry
  // Skip symlinks entirely. Libero walks controlled source trees only;
  // following a symlink risks infinite loops on cycles (e.g. a link back
  // to a parent directory) and the target either lives inside the scan
  // root already (in which case it's walked directly) or lives outside
  // it, in which case it shouldn't contribute to generated output.
  use <- bool.guard(
    when: simplifile.is_symlink(child) |> result.unwrap(False),
    return: Ok(acc),
  )
  let is_dir = result.unwrap(simplifile.is_directory(child), False)
  case is_dir {
    True -> visit_subdirectory(acc: acc, entry: entry, child: child)
    False -> Ok(visit_file(acc: acc, entry: entry, child: child))
  }
}

fn visit_subdirectory(
  acc acc: List(String),
  entry entry: String,
  child child: String,
) -> Result(List(String), GenError) {
  use <- bool.guard(when: entry == "generated", return: Ok(acc))
  use nested <- result.try(walk_directory(path: child))
  Ok(list.append(nested, acc))
}

fn visit_file(
  acc acc: List(String),
  entry entry: String,
  child child: String,
) -> List(String) {
  use <- bool.guard(when: !string.ends_with(entry, ".gleam"), return: acc)
  [child, ..acc]
}

// ---------- Module path derivation ----------

/// Derive the Gleam module path from a file path by finding `/src/` and
/// taking everything after it, then stripping the `.gleam` extension.
/// E.g. `examples/todos/shared/src/shared/todos.gleam` -> `shared/todos`.
pub fn derive_module_path(file_path file_path: String) -> String {
  let without_extension = case string.ends_with(file_path, ".gleam") {
    True ->
      string.slice(
        from: file_path,
        at_index: 0,
        length: string.length(file_path) - string.length(".gleam"),
      )
    False -> file_path
  }
  string.split_once(without_extension, "/src/")
  |> result.map(fn(pair) { pair.1 })
  |> result.unwrap(or: without_extension)
}

// ---------- Convention validation ----------

/// Validate that the server package follows the conventions required for
/// code generation:
/// 1. `server/shared_state.gleam` exists
/// 2. `server/app_error.gleam` exists
/// 3. For each message module with `has_msg_from_client`, a handler exists at
///    `server/handlers/<module_segment>.gleam`
///
/// Returns a list of errors (empty list means all conventions are satisfied).
pub fn validate_conventions(
  message_modules message_modules: List(MessageModule),
  server_src server_src: String,
) -> List(GenError) {
  let shared_state_path = server_src <> "/server/shared_state.gleam"
  let app_error_path = server_src <> "/server/app_error.gleam"

  let shared_state_exists =
    simplifile.is_file(shared_state_path) |> result.unwrap(or: False)
  let shared_state_errors = case shared_state_exists {
    True -> []
    False -> [MissingSharedState(expected_path: shared_state_path)]
  }

  let app_error_exists =
    simplifile.is_file(app_error_path) |> result.unwrap(or: False)
  let app_error_errors = case app_error_exists {
    True -> []
    False -> [MissingAppError(expected_path: app_error_path)]
  }

  let handler_errors =
    list.flat_map(message_modules, fn(m) {
      case m.has_msg_from_client {
        False -> []
        True -> {
          let segment = last_module_segment(module_path: m.module_path)
          let handler_path =
            server_src <> "/server/handlers/" <> segment <> ".gleam"
          let handler_exists =
            simplifile.is_file(handler_path) |> result.unwrap(or: False)
          case handler_exists {
            True -> []
            False -> [
              MissingHandler(
                message_module: m.module_path,
                expected_path: handler_path,
              ),
            ]
          }
        }
      }
    })

  list.flatten([shared_state_errors, app_error_errors, handler_errors])
}

/// Extract the last path segment from a module path.
/// E.g. `shared/todos` -> `todos`, `todos` -> `todos`.
pub fn last_module_segment(module_path module_path: String) -> String {
  string.split(module_path, "/")
  |> list.last
  |> result.unwrap(or: module_path)
}
