//// Scanning for handler-as-contract endpoints.
////
//// Walks the server source tree to discover handler functions whose
//// signatures define the wire contract: each public function with last
//// parameter `HandlerContext`, return type `#(_, HandlerContext)`, and
//// all other types from shared/.

import glance
import gleam/bool
import gleam/dict
import gleam/list
import gleam/option
import gleam/result
import gleam/set
import gleam/string
import libero/field_type
import libero/gen_error.{
  type GenError, CannotReadDir, CannotReadFile, ParseFailed,
}
import simplifile

// ---------- Types ----------

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
/// E.g. `examples/checklist/shared/src/shared/items.gleam` -> `shared/items`.
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

/// Extract the last path segment from a module path.
/// E.g. `shared/items` -> `items`, `items` -> `items`.
pub fn last_module_segment(module_path module_path: String) -> String {
  string.split(module_path, "/")
  |> list.last
  |> result.unwrap(or: module_path)
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
  // Build a set of shared type names from the shared source directory.
  use shared_types <- result.try(scan_shared_type_names(shared_src))
  use files <- result.try(
    walk_directory(path: server_src)
    |> result.map_error(fn(cause) { [cause] }),
  )
  // Run parse_endpoints across every handler file, collecting both the
  // endpoints and any read/parse errors encountered. Surface failures
  // instead of silently dropping them, since a file that fails to parse
  // would otherwise produce zero endpoints with no warning.
  let #(endpoints_rev, errors_rev) =
    list.fold(files, #([], []), fn(acc, file_path) {
      let #(eps_acc, errs_acc) = acc
      case parse_endpoints(file_path:, shared_types:) {
        Ok(eps) -> #(list.append(list.reverse(eps), eps_acc), errs_acc)
        Error(err) -> #(eps_acc, [err, ..errs_acc])
      }
    })
  case errors_rev {
    [] -> Ok(list.reverse(endpoints_rev))
    _ -> Error(list.reverse(errors_rev))
  }
}

/// Scan shared source directory and collect all exported type names.
fn scan_shared_type_names(
  shared_src: String,
) -> Result(set.Set(String), List(GenError)) {
  use files <- result.try(
    walk_directory(path: shared_src)
    |> result.map_error(fn(cause) { [cause] }),
  )
  let #(names_set, errors_rev) =
    list.fold(files, #(set.new(), []), fn(acc, file_path) {
      let #(set_acc, errs_acc) = acc
      case read_public_type_names(file_path) {
        Ok(names) -> #(list.fold(names, set_acc, set.insert), errs_acc)
        Error(err) -> #(set_acc, [err, ..errs_acc])
      }
    })
  case errors_rev {
    [] -> Ok(names_set)
    _ -> Error(list.reverse(errors_rev))
  }
}

fn read_public_type_names(file_path: String) -> Result(List(String), GenError) {
  use content <- result.try(
    simplifile.read(file_path)
    |> result.map_error(fn(cause) { CannotReadFile(path: file_path, cause:) }),
  )
  use parsed <- result.map(
    glance.module(content)
    |> result.map_error(fn(cause) { ParseFailed(path: file_path, cause:) }),
  )
  list.fold(parsed.custom_types, [], fn(acc, ct) {
    let glance.Definition(_, t) = ct
    case t.publicity == glance.Public {
      True -> [t.name, ..acc]
      False -> acc
    }
  })
}

fn parse_endpoints(
  file_path file_path: String,
  shared_types shared_types: set.Set(String),
) -> Result(List(HandlerEndpoint), GenError) {
  use content <- result.try(
    simplifile.read(file_path)
    |> result.map_error(fn(cause) { CannotReadFile(path: file_path, cause:) }),
  )
  use parsed <- result.map(
    glance.module(content)
    |> result.map_error(fn(cause) { ParseFailed(path: file_path, cause:) }),
  )
  let module_path = derive_module_path(file_path: file_path)
  let type_imports = build_type_import_map(parsed.imports)
  let alias_map = build_alias_resolution_map(parsed.imports)
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
  })
}

/// Build a map from unqualified type names to the FULL module path of
/// their import. e.g. `import shared/items.{type Item}` produces
/// {"Item": "shared/items"}. Used by structured type resolution
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
