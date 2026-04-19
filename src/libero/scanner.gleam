//// Scanning and convention validation for message modules.
////
//// Discovers modules in the shared package that export `MsgFromClient` or
//// `MsgFromServer` custom types, and validates that the server package
//// follows the required conventions (handler modules, shared state, etc.).
//// Handlers are discovered by scanning server source for modules that export
//// `pub fn update_from_client` and matching via the first parameter's type.

import glance
import gleam/bool
import gleam/dict.{type Dict}
import gleam/io
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import libero/gen_error.{
  type GenError, CannotReadDir, CannotReadFile, CannotWriteFile, MissingHandler,
  MsgFromServerFieldCount, NoMessageModules, ParseFailed,
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
    /// The server modules that handle MsgFromClient for this message module,
    /// e.g. ["server/store"]. Empty if no handler found or not applicable.
    handler_modules: List(String),
  )
}

/// A discovered handler: a server module exporting `pub fn update_from_client`
/// with the shared module path it handles (resolved from the msg parameter type).
type DiscoveredHandler {
  DiscoveredHandler(
    /// The server module path, e.g. "server/store"
    handler_module: String,
    /// The shared module path this handler serves, e.g. "shared/todos"
    shared_module: String,
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
    |> result.map_error(fn(cause) {
      [cause, NoMessageModules(shared_path: shared_src)]
    })
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
  Ok(
    MessageModule(
      module_path: module_path,
      file_path: file_path,
      has_msg_from_client: has_msg_from_client,
      has_msg_from_server: has_msg_from_server,
      handler_modules: [],
    ),
  )
}

// ---------- Handler discovery ----------

/// Scan server source for modules that export `pub fn update_from_client`.
/// For each such function, resolve the first parameter's type annotation to
/// determine which shared message module it handles.
fn scan_handlers(
  server_src server_src: String,
) -> Result(List(DiscoveredHandler), List(GenError)) {
  let files =
    walk_directory(path: server_src)
    |> result.map_error(fn(cause) { [cause] })
  use files <- result.try(files)
  Ok(
    list.filter_map(files, fn(file_path) { parse_handler(file_path: file_path) }),
  )
}

/// Parse a single server source file looking for `pub fn update_from_client`.
/// If found, resolve the first parameter's type to a shared module path.
fn parse_handler(file_path file_path: String) -> Result(DiscoveredHandler, Nil) {
  use content <- result.try(
    simplifile.read(file_path)
    |> result.replace_error(Nil),
  )
  use parsed <- result.try(
    glance.module(content)
    |> result.replace_error(Nil),
  )
  // Find pub fn update_from_client
  let target =
    list.find(parsed.functions, fn(def) {
      let glance.Definition(_, f) = def
      f.name == "update_from_client" && f.publicity == glance.Public
    })
  use glance.Definition(_, func) <- result.try(target)
  // Get first parameter's type annotation
  use first_param <- result.try(list.first(func.parameters))
  use type_ann <- result.try(option.to_result(first_param.type_, Nil))
  // Resolve the type to a shared module path
  use shared_module <- result.try(resolve_msg_type(
    type_ann: type_ann,
    imports: parsed.imports,
  ))
  let handler_module = derive_module_path(file_path: file_path)
  Ok(DiscoveredHandler(
    handler_module: handler_module,
    shared_module: shared_module,
  ))
}

/// Resolve a type annotation to the shared module path it refers to.
/// Handles both qualified (`todos.MsgFromClient`) and unqualified
/// (`MsgFromClient`) references.
fn resolve_msg_type(
  type_ann type_ann: glance.Type,
  imports imports: List(glance.Definition(glance.Import)),
) -> Result(String, Nil) {
  case type_ann {
    glance.NamedType(name: "MsgFromClient", module: option.Some(qualifier), ..) ->
      // Qualified: e.g. `todos.MsgFromClient` - find import matching qualifier
      resolve_qualified(qualifier: qualifier, imports: imports)
    glance.NamedType(name: "MsgFromClient", module: option.None, ..) ->
      // Unqualified: find which import has MsgFromClient in unqualified_types
      resolve_unqualified(type_name: "MsgFromClient", imports: imports)
    _ -> Error(Nil)
  }
}

/// Resolve a qualified type reference like `todos.MsgFromClient`.
/// The qualifier matches either an import alias or the last segment of the
/// import module path.
fn resolve_qualified(
  qualifier qualifier: String,
  imports imports: List(glance.Definition(glance.Import)),
) -> Result(String, Nil) {
  list.find_map(imports, fn(def) {
    let glance.Definition(_, imp) = def
    let matches = case imp.alias {
      option.Some(glance.Named(alias_name)) -> alias_name == qualifier
      option.Some(glance.Discarded(_)) -> False
      option.None -> {
        // Default qualifier is last segment of module path
        let segments = string.split(imp.module, "/")
        case list.last(segments) {
          Ok(last) -> last == qualifier
          Error(Nil) -> False
        }
      }
    }
    case matches {
      True -> Ok(imp.module)
      False -> Error(Nil)
    }
  })
}

/// Resolve an unqualified type reference like `MsgFromClient`.
/// Search unqualified_types across all imports.
fn resolve_unqualified(
  type_name type_name: String,
  imports imports: List(glance.Definition(glance.Import)),
) -> Result(String, Nil) {
  list.find_map(imports, fn(def) {
    let glance.Definition(_, imp) = def
    let has_type =
      list.any(imp.unqualified_types, fn(uq) { uq.name == type_name })
    case has_type {
      True -> Ok(imp.module)
      False -> Error(Nil)
    }
  })
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
/// 3. For each message module with `has_msg_from_client`, a server module
///    exports `pub fn update_from_client` with the correct msg type
///
/// Returns `Ok(#(updated_modules, errors))` where updated_modules have
/// `handler_module` populated from discovered handlers. Errors are fatal
/// only if non-empty.
pub fn validate_conventions(
  message_modules message_modules: List(MessageModule),
  server_src server_src: String,
  shared_state_path shared_state_path: String,
  app_error_path app_error_path: String,
) -> Result(List(MessageModule), List(GenError)) {

  let shared_state_errors = case
    simplifile.is_file(shared_state_path) |> result.unwrap(or: False)
  {
    True -> []
    False -> scaffold_shared_state(shared_state_path)
  }

  let app_error_errors = case
    simplifile.is_file(app_error_path) |> result.unwrap(or: False)
  {
    True -> []
    False -> scaffold_app_error(app_error_path)
  }

  // Scan server source for handler modules
  let handlers_result = scan_handlers(server_src: server_src)
  let #(handlers, scan_errors) = case handlers_result {
    Ok(h) -> #(h, [])
    Error(errs) -> #([], errs)
  }

  // Match a message module to its handler(s), returning an error if missing.
  let match_handler = fn(
    m: MessageModule,
    handler_map: Dict(String, List(String)),
  ) -> #(MessageModule, option.Option(GenError)) {
    case m.has_msg_from_client, dict.get(handler_map, m.module_path) {
      False, _ -> #(MessageModule(..m, handler_modules: []), option.None)
      True, Ok(handler_list) -> #(
        MessageModule(..m, handler_modules: handler_list),
        option.None,
      )
      True, Error(Nil) -> #(
        MessageModule(..m, handler_modules: []),
        option.Some(MissingHandler(
          message_module: m.module_path,
          expected: "a server module exporting pub fn update_from_client with msg: "
            <> m.module_path
            <> ".MsgFromClient",
        )),
      )
    }
  }

  // Build a dict from shared_module -> List(handler_module) for quick lookup.
  // Multiple server modules can handle the same shared message module.
  let handler_map =
    list.fold(handlers, dict.new(), fn(acc, h) {
      let existing = dict.get(acc, h.shared_module) |> result.unwrap([])
      dict.insert(
        acc,
        h.shared_module,
        list.append(existing, [h.handler_module]),
      )
    })

  // Match handlers to message modules and collect missing handler errors
  let #(updated_modules, handler_errors) =
    list.fold(message_modules, #([], []), fn(acc, m) {
      let #(modules_acc, errors_acc) = acc
      let #(updated, new_err) = match_handler(m, handler_map)
      let new_errors = case new_err {
        option.Some(err) -> [err, ..errors_acc]
        option.None -> errors_acc
      }
      #([updated, ..modules_acc], new_errors)
    })

  let all_errors =
    list.flatten([
      shared_state_errors,
      app_error_errors,
      scan_errors,
      list.reverse(handler_errors),
    ])

  case all_errors {
    [] -> Ok(list.reverse(updated_modules))
    _ -> Error(all_errors)
  }
}

/// Scaffold a default shared_state.gleam if missing.
/// Returns an empty error list on success so it integrates
/// with the existing error-collection flow.
fn scaffold_shared_state(path: String) -> List(GenError) {
  let content =
    "/// Replace this with your application's shared state type.
/// If your state lives in ETS or a database, this unit type
/// is fine as-is.

pub type SharedState {
  SharedState
}

pub fn new() -> SharedState {
  SharedState
}
"
  case simplifile.write(path, content) {
    Ok(Nil) -> {
      io.println("  scaffolded " <> path)
      []
    }
    Error(cause) -> [CannotWriteFile(path:, cause:)]
  }
}

/// Scaffold a default app_error.gleam if missing.
fn scaffold_app_error(path: String) -> List(GenError) {
  let content =
    "/// Replace this with your application's error type.
/// Handlers return Result(#(MsgFromServer, SharedState), AppError),
/// and AppError values are sent to the client as typed errors.

pub type AppError {
  AppError(String)
}
"
  case simplifile.write(path, content) {
    Ok(Nil) -> {
      io.println("  scaffolded " <> path)
      []
    }
    Error(cause) -> [CannotWriteFile(path:, cause:)]
  }
}

/// Validate that every MsgFromServer variant has at most one field.
/// Dispatch unwraps the envelope with `element(2, Tuple)` in Erlang,
/// which silently drops extra fields. Zero-field variants (bare atoms)
/// are fine, they unwrap to Nil.
pub fn validate_msg_from_server_fields(
  message_modules message_modules: List(MessageModule),
) -> Result(Nil, List(GenError)) {
  let errors =
    list.flat_map(message_modules, fn(m) {
      case m.has_msg_from_server {
        False -> []
        True -> check_variant_fields(m)
      }
    })
  case errors {
    [] -> Ok(Nil)
    _ -> Error(errors)
  }
}

fn check_variant_fields(m: MessageModule) -> List(GenError) {
  use source <- read_or_error(m)
  use ast <- parse_or_error(m, source)
  let msg_from_server =
    list.find(ast.custom_types, fn(d) { d.definition.name == "MsgFromServer" })
  case msg_from_server {
    Error(Nil) -> []
    Ok(ct_def) ->
      list.filter_map(ct_def.definition.variants, fn(variant) {
        let field_count = list.length(variant.fields)
        case field_count {
          0 | 1 -> Error(Nil)
          _ ->
            Ok(MsgFromServerFieldCount(
              module_path: m.module_path,
              variant_name: variant.name,
              field_count: field_count,
            ))
        }
      })
  }
}

fn read_or_error(
  module m: MessageModule,
  next next: fn(String) -> List(GenError),
) -> List(GenError) {
  case simplifile.read(m.file_path) {
    Error(cause) -> [CannotReadFile(path: m.file_path, cause:)]
    Ok(source) -> next(source)
  }
}

fn parse_or_error(
  module m: MessageModule,
  source source: String,
  next next: fn(glance.Module) -> List(GenError),
) -> List(GenError) {
  case glance.module(source) {
    Error(cause) -> [ParseFailed(path: m.file_path, cause:)]
    Ok(ast) -> next(ast)
  }
}

/// Extract the last path segment from a module path.
/// E.g. `shared/todos` -> `todos`, `todos` -> `todos`.
pub fn last_module_segment(module_path module_path: String) -> String {
  string.split(module_path, "/")
  |> list.last
  |> result.unwrap(or: module_path)
}
