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
import gleam/set
import gleam/string
import libero/field_type
import libero/gen_error.{
  type GenError, CannotReadDir, CannotReadFile, CannotWriteFile, MissingHandler,
  MsgFromServerFieldCount, NoMessageModules, ParseFailed,
}
import simplifile

// ---------- Types ----------

/// Info about a single handler module and which MsgFromClient variants it handles.
pub type HandlerInfo {
  HandlerInfo(
    /// The server module path, e.g. "server/store"
    module_path: String,
    /// MsgFromClient constructor names matched in the case arms
    handled_variants: List(String),
  )
}

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
    /// The server modules that handle MsgFromClient for this message module.
    /// Empty if no handler found or not applicable.
    handlers: List(HandlerInfo),
  )
}

/// A single handler endpoint discovered by scanning function signatures.
/// Each represents one RPC function that clients can call.
pub type HandlerEndpoint {
  HandlerEndpoint(
    /// Handler module path, e.g. "server/handler"
    module_path: String,
    /// Function name, e.g. "get_todos"
    fn_name: String,
    /// Structured return type, with module-qualified user types resolved
    /// to their full path. Codegen pattern-matches on this directly
    /// instead of re-parsing strings — the failure mode that made the
    /// `bool.guard`-recursion bug class possible.
    return_type: field_type.FieldType,
    /// Parameters excluding state, with labels and resolved types.
    /// Each entry is #(label, FieldType).
    params: List(#(String, field_type.FieldType)),
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
    /// MsgFromClient constructor names matched in the case arms
    handled_variants: List(String),
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
      handlers: [],
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
fn parse_handler(
  file_path file_path: String,
) -> Result(DiscoveredHandler, Nil) {
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
  let handled_variants = extract_handled_variants(func)
  Ok(DiscoveredHandler(
    handler_module: handler_module,
    shared_module: shared_module,
    handled_variants: handled_variants,
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

// ---------- Variant extraction ----------

/// Extract MsgFromClient variant names from the case arms in update_from_client.
fn extract_handled_variants(func: glance.Function) -> List(String) {
  list.flat_map(func.body, fn(stmt) {
    case stmt {
      glance.Expression(glance.Case(subjects: _, clauses:, ..)) ->
        extract_variant_names(clauses)
      _ -> []
    }
  })
}

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

// ---------- Source discovery ----------

/// Recursively walk a directory, returning every `.gleam` file found.
/// Skips any subdirectory named `generated`, since libero never reads its
/// own output, and leaving this convention in place means consumers
/// don't need to configure scan_excludes as their projects grow.
///
/// Results are sorted alphabetically so codegen output is deterministic
/// across runs and across machines (filesystem order is not stable).
pub fn walk_directory(path path: String) -> Result(List(String), GenError) {
  use entries <- result.try(
    simplifile.read_directory(path)
    |> result.map_error(fn(cause) { CannotReadDir(path: path, cause: cause) }),
  )
  use files <- result.map(
    list.try_fold(over: entries, from: [], with: fn(acc, entry) {
      visit_entry(acc: acc, parent: path, entry: entry)
    }),
  )
  list.sort(files, by: string.compare)
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
/// 1. `server/handler_context.gleam` exists
/// 2. For each message module with `has_msg_from_client`, a server module
///    exports `pub fn update_from_client` with the correct msg type
///
/// Returns `Ok(#(updated_modules, errors))` where updated_modules have
/// `handler_module` populated from discovered handlers. Errors are fatal
/// only if non-empty.
pub fn validate_conventions(
  message_modules message_modules: List(MessageModule),
  server_src server_src: String,
  context_path context_path: String,
) -> Result(List(MessageModule), List(GenError)) {
  let context_errors = case
    simplifile.is_file(context_path) |> result.unwrap(or: False)
  {
    True -> []
    False -> scaffold_context(context_path)
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
    handler_map: Dict(String, List(HandlerInfo)),
  ) -> #(MessageModule, option.Option(GenError)) {
    case m.has_msg_from_client, dict.get(handler_map, m.module_path) {
      False, _ -> #(MessageModule(..m, handlers: []), option.None)
      True, Ok(handler_list) -> #(
        MessageModule(..m, handlers: handler_list),
        option.None,
      )
      True, Error(Nil) -> #(
        MessageModule(..m, handlers: []),
        option.Some(MissingHandler(
          message_module: m.module_path,
          expected: "a server module exporting pub fn update_from_client with msg: "
            <> m.module_path
            <> ".MsgFromClient",
        )),
      )
    }
  }

  // Build a dict from shared_module -> List(HandlerInfo) for quick lookup.
  // Multiple server modules can handle the same shared message module.
  let handler_map =
    list.fold(handlers, dict.new(), fn(acc, h) {
      let existing = dict.get(acc, h.shared_module) |> result.unwrap([])
      let info =
        HandlerInfo(
          module_path: h.handler_module,
          handled_variants: h.handled_variants,
        )
      dict.insert(acc, h.shared_module, list.append(existing, [info]))
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
      context_errors,
      scan_errors,
      list.reverse(handler_errors),
    ])

  case all_errors {
    [] -> Ok(list.reverse(updated_modules))
    _ -> Error(all_errors)
  }
}

/// Scaffold a default context.gleam if missing.
/// Returns an empty error list on success so it integrates
/// with the existing error-collection flow.
fn scaffold_context(path: String) -> List(GenError) {
  let content =
    "/// Replace this with your application's handler context type.
/// If your state lives in ETS or a database, this unit type
/// is fine as-is.

pub type HandlerContext {
  HandlerContext
}

pub fn new() -> HandlerContext {
  HandlerContext
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

/// Find the module path of the alphabetically first .gleam file in the shared
/// src directory. Used by the endpoint convention to determine the wire
/// envelope module path.
///
/// The choice is arbitrary but stable (walk_directory sorts its output), which
/// is what the wire envelope needs. For projects with multiple shared modules,
/// callers should consider exposing a config knob; today the auto-detection
/// just picks the first one alphabetically.
pub fn scan_shared_module_path(
  shared_src shared_src: String,
) -> Result(String, Nil) {
  case walk_directory(path: shared_src) {
    Ok(files) ->
      case list.first(files) {
        Ok(file_path) -> Ok(derive_module_path(file_path: file_path))
        Error(Nil) -> Error(Nil)
      }
    Error(_) -> Error(Nil)
  }
}

// ---------- Handler endpoint scanning ----------

/// Scan server source for handler endpoint functions.
/// A handler endpoint is any public function whose last parameter
/// is typed as HandlerContext, return type is #(something, HandlerContext),
/// and all types in params/return are from shared/ or builtins.
pub fn scan_handler_endpoints(
  server_src server_src: String,
  shared_src shared_src: String,
) -> Result(List(HandlerEndpoint), List(GenError)) {
  // Build a set of shared type names from the shared source directory
  let shared_types = scan_shared_type_names(shared_src)
  let files =
    walk_directory(path: server_src)
    |> result.map_error(fn(cause) { [cause] })
  use files <- result.try(files)
  let endpoints =
    list.flat_map(files, fn(file_path) {
      parse_endpoints(file_path:, shared_types:)
    })
  Ok(endpoints)
}

/// Scan shared source directory and collect all exported type names.
fn scan_shared_type_names(shared_src: String) -> set.Set(String) {
  let files = result.unwrap(walk_directory(path: shared_src), or: [])
  list.fold(files, set.new(), fn(acc, file_path) {
    let type_names = read_public_type_names(file_path)
    list.fold(type_names, acc, set.insert)
  })
}

fn read_public_type_names(file_path: String) -> List(String) {
  let names = {
    use content <- result.try(result.replace_error(
      simplifile.read(file_path),
      Nil,
    ))
    use parsed <- result.try(result.replace_error(glance.module(content), Nil))
    Ok(
      list.fold(parsed.custom_types, [], fn(acc, ct) {
        let glance.Definition(_, t) = ct
        case t.publicity == glance.Public {
          True -> [t.name, ..acc]
          False -> acc
        }
      }),
    )
  }
  result.unwrap(names, or: [])
}

fn parse_endpoints(
  file_path file_path: String,
  shared_types shared_types: set.Set(String),
) -> List(HandlerEndpoint) {
  let result = {
    use content <- result.try(
      simplifile.read(file_path) |> result.replace_error(Nil),
    )
    use parsed <- result.try(
      glance.module(content) |> result.replace_error(Nil),
    )
    let module_path = derive_module_path(file_path: file_path)
    let type_imports = build_type_import_map(parsed.imports)
    let alias_map = build_alias_resolution_map(parsed.imports)
    Ok(
      list.filter_map(parsed.functions, fn(def) {
        let glance.Definition(_, func) = def
        case func.publicity == glance.Public {
          False -> Error(Nil)
          True ->
            parse_single_endpoint(
              func: func,
              module_path: module_path,
              type_imports: type_imports,
              alias_map: alias_map,
              shared_types: shared_types,
            )
        }
      }),
    )
  }
  case result {
    Ok(endpoints) -> endpoints
    Error(Nil) -> []
  }
}

/// Build a map from unqualified type names to the FULL module path of
/// their import. e.g. `import shared/messages.{type Todo}` produces
/// {"Todo": "shared/messages"}. Used by structured type resolution
/// where downstream codegen needs the full path for decoder function
/// naming (`decoder_fn_name(module_path, type_name)`).
fn build_type_import_map(
  imports: List(glance.Definition(glance.Import)),
) -> dict.Dict(String, String) {
  list.fold(imports, dict.new(), fn(acc, def) {
    let glance.Definition(_, imp) = def
    list.fold(imp.unqualified_types, acc, fn(inner_acc, uq) {
      dict.insert(inner_acc, uq.name, imp.module)
    })
  })
}

/// Build a map from import aliases (and bare module names) to the full
/// module path. e.g. `import shared/line_items_report as wire` produces
/// {"wire": "shared/line_items_report"}. Unaliased imports produce
/// identity entries keyed by the last segment.
fn build_alias_resolution_map(
  imports: List(glance.Definition(glance.Import)),
) -> dict.Dict(String, String) {
  list.fold(imports, dict.new(), fn(acc, def) {
    let glance.Definition(_, imp) = def
    let last_seg = last_module_segment(module_path: imp.module)
    let alias = case imp.alias {
      option.Some(glance.Named(name)) -> name
      _ -> last_seg
    }
    dict.insert(acc, alias, imp.module)
  })
}

fn parse_single_endpoint(
  func func: glance.Function,
  module_path module_path: String,
  type_imports type_imports: dict.Dict(String, String),
  alias_map alias_map: dict.Dict(String, String),
  shared_types shared_types: set.Set(String),
) -> Result(HandlerEndpoint, Nil) {
  // Skip update_from_client (old convention)
  use <- bool.guard(when: func.name == "update_from_client", return: Error(Nil))

  // Must have at least one parameter
  let params = func.parameters
  use <- bool.guard(when: list.is_empty(params), return: Error(Nil))

  // Last parameter must be typed as HandlerContext
  use last_param <- result.try(list.last(params))
  use last_type <- result.try(option.to_result(last_param.type_, Nil))
  use <- bool.guard(
    when: !is_handler_context_type(last_type),
    return: Error(Nil),
  )

  // Return type must be a tuple #(something, HandlerContext)
  use return_type <- result.try(option.to_result(func.return, Nil))
  use #(response_type, _state_type) <- result.try(extract_handler_return(
    return_type,
  ))

  // The response slot must be a Result(_, _). The wire envelope, dispatch,
  // and client codecs all assume Result-shaped responses; a bare value here
  // would compile but produce broken serialization at runtime. Treat it as
  // "not an endpoint" so we don't silently emit broken codegen.
  use <- bool.guard(when: !is_result_type(response_type), return: Error(Nil))

  // Extract non-state parameters with their labels and structured types.
  let non_state_params = list.take(params, list.length(params) - 1)
  let params_typed =
    list.filter_map(non_state_params, fn(p) {
      case p.label, p.type_ {
        option.Some(label), option.Some(type_) ->
          Ok(#(
            label,
            glance_type_to_field_type(
              type_: type_,
              imports: type_imports,
              aliases: alias_map,
            ),
          ))
        _, _ -> Error(Nil)
      }
    })

  // All non-builtin types must be from shared/
  let all_param_types =
    list.filter_map(non_state_params, fn(p) { option.to_result(p.type_, Nil) })
  let all_types = [response_type, ..all_param_types]
  use <- bool.guard(
    when: !all_types_shared(all_types, shared_types),
    return: Error(Nil),
  )

  Ok(HandlerEndpoint(
    module_path: module_path,
    fn_name: func.name,
    return_type: glance_type_to_field_type(
      type_: response_type,
      imports: type_imports,
      aliases: alias_map,
    ),
    params: params_typed,
  ))
}

/// Check if a type annotation is HandlerContext (possibly qualified).
fn is_handler_context_type(t: glance.Type) -> Bool {
  case t {
    glance.NamedType(name: "HandlerContext", ..) -> True
    _ -> False
  }
}

/// Check if a type annotation is a Result(_, _).
fn is_result_type(t: glance.Type) -> Bool {
  case t {
    glance.NamedType(name: "Result", parameters: [_, _], ..) -> True
    _ -> False
  }
}

/// Extract the two elements from a #(response, HandlerContext) return type.
/// Returns Error(Nil) if the return type doesn't match this pattern.
fn extract_handler_return(
  t: glance.Type,
) -> Result(#(glance.Type, glance.Type), Nil) {
  case t {
    glance.TupleType(elements: [response, state], ..) ->
      case is_handler_context_type(state) {
        True -> Ok(#(response, state))
        False -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

/// Convert a glance.Type AST into a structured FieldType, resolving
/// module-qualified types to their full paths via the supplied maps.
///
/// `imports` and `aliases` map unqualified names and module aliases
/// (respectively) to FULL module paths (e.g. "shared/types"). See
/// `build_type_import_map` and `build_alias_resolution_map`.
fn glance_type_to_field_type(
  type_ t: glance.Type,
  imports imports: dict.Dict(String, String),
  aliases aliases: dict.Dict(String, String),
) -> field_type.FieldType {
  case t {
    glance.NamedType(name:, module: option.None, parameters: [], ..) ->
      builtin_or_user(name:, parameters: [], imports:, aliases:)
    glance.NamedType(name:, module: option.None, parameters: params, ..) ->
      builtin_or_user(name:, parameters: params, imports:, aliases:)
    glance.NamedType(name:, module: option.Some(m), parameters: params, ..) -> {
      let module_path = dict.get(aliases, m) |> result.unwrap(or: m)
      field_type.UserType(
        module_path:,
        type_name: name,
        args: list.map(params, fn(p) {
          glance_type_to_field_type(type_: p, imports:, aliases:)
        }),
      )
    }
    glance.TupleType(elements:, ..) ->
      field_type.TupleOf(
        elements: list.map(elements, fn(e) {
          glance_type_to_field_type(type_: e, imports:, aliases:)
        }),
      )
    glance.VariableType(name:, ..) -> field_type.TypeVar(name:)
    glance.FunctionType(..) -> field_type.TypeVar(name: "_fn")
    glance.HoleType(..) -> field_type.TypeVar(name: "_")
  }
}

/// Resolve a non-module-qualified named type. Builtins return their
/// FieldType directly. Other names are looked up in `imports` to
/// produce a `UserType` with the import's full module path. Unknown
/// names fall back to a `UserType` with the bare name as `module_path`
/// — caller is expected to have validated all types via
/// `all_types_shared` first, so this branch is unreachable in practice.
fn builtin_or_user(
  name name: String,
  parameters parameters: List(glance.Type),
  imports imports: dict.Dict(String, String),
  aliases aliases: dict.Dict(String, String),
) -> field_type.FieldType {
  let recurse = fn(t) {
    glance_type_to_field_type(type_: t, imports:, aliases:)
  }
  case name, parameters {
    "Int", [] -> field_type.IntField
    "Float", [] -> field_type.FloatField
    "String", [] -> field_type.StringField
    "Bool", [] -> field_type.BoolField
    "BitArray", [] -> field_type.BitArrayField
    "Nil", [] -> field_type.NilField
    "List", [elem] -> field_type.ListOf(element: recurse(elem))
    "Option", [inner] -> field_type.OptionOf(inner: recurse(inner))
    "Result", [ok, err] ->
      field_type.ResultOf(ok: recurse(ok), err: recurse(err))
    "Dict", [key, val] ->
      field_type.DictOf(key: recurse(key), value: recurse(val))
    _, _ -> {
      let module_path = dict.get(imports, name) |> result.unwrap(or: name)
      field_type.UserType(
        module_path:,
        type_name: name,
        args: list.map(parameters, recurse),
      )
    }
  }
}

/// Check that all types in a list are shared types or builtins.
/// Walks type parameters recursively (e.g. List(Todo) checks Todo).
fn all_types_shared(
  types: List(glance.Type),
  shared_types: set.Set(String),
) -> Bool {
  list.all(types, fn(t) { is_type_shared(t, shared_types) })
}

/// Check if a single type (and all its parameters) are shared or builtins.
fn is_type_shared(t: glance.Type, shared_types: set.Set(String)) -> Bool {
  let builtins =
    set.from_list([
      "Int", "String", "Float", "Bool", "Nil", "List", "Result", "Option",
      "Dict", "BitArray", "Dynamic",
    ])
  case t {
    glance.NamedType(name:, parameters:, ..) ->
      { set.contains(builtins, name) || set.contains(shared_types, name) }
      && list.all(parameters, fn(p) { is_type_shared(p, shared_types) })
    glance.TupleType(elements:, ..) ->
      list.all(elements, fn(e) { is_type_shared(e, shared_types) })
    glance.VariableType(..) -> True
    glance.FunctionType(parameters:, return:, ..) ->
      list.all(parameters, fn(p) { is_type_shared(p, shared_types) })
      && is_type_shared(return, shared_types)
    glance.HoleType(..) -> True
  }
}
