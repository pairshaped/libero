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
  type GenError, CannotReadDir, CannotReadFile, DuplicateEndpoint, ParseFailed,
}
import simplifile

// ---------- Types ----------

/// A single handler endpoint discovered by scanning function signatures.
/// Each represents one RPC function that clients can call.
///
/// Scanner enforces that every endpoint's return shape is `Result(ok, err)`,
/// so the two halves are stored separately rather than under a broader
/// `FieldType` that would force every consumer to re-pattern-match.
pub type HandlerEndpoint {
  HandlerEndpoint(
    /// Handler module path, e.g. "server/handler"
    module_path: String,
    /// Function name, e.g. "get_items"
    fn_name: String,
    /// Ok payload of the handler's `Result`, with module-qualified user
    /// types resolved to their full path.
    return_ok: field_type.FieldType,
    /// Err payload of the handler's `Result`.
    return_err: field_type.FieldType,
    /// Parameters excluding HandlerContext, with labels and resolved
    /// types. Each entry is #(label, FieldType).
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
  let is_symlink = simplifile.is_symlink(child) |> result.unwrap(False)
  let is_dir = result.unwrap(simplifile.is_directory(child), False)
  // Skip symlinked DIRECTORIES only; following them risks infinite loops
  // on cycles (a link back to a parent), and any directory inside the
  // scan root is already being walked directly. Symlinked files don't
  // loop, and a developer who symlinks a `.gleam` file into a handler
  // tree (vendored fixtures, shared base files) reasonably expects it
  // to participate.
  use <- bool.guard(when: is_symlink && is_dir, return: Ok(acc))
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

/// Derive the Gleam module path from a file path by finding the last
/// occurrence of `/src/` and taking everything after it, then stripping
/// the `.gleam` extension. Splitting on the LAST `/src/` (not the first)
/// matters for vendored paths like `vendor/x/src/lib/src/types.gleam`,
/// where the leftmost match would yield the wrong module path.
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
  case string.split(without_extension, "/src/") {
    [_only] -> without_extension
    parts -> list.last(parts) |> result.unwrap(or: without_extension)
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
    [] -> {
      let endpoints = list.reverse(endpoints_rev)
      case duplicate_fn_name_errors(endpoints) {
        [] -> Ok(endpoints)
        dup_errors -> Error(dup_errors)
      }
    }
    _ -> Error(list.reverse(errors_rev))
  }
}

/// Detect handler functions sharing a name across modules. Each duplicate
/// would compile into the same ClientMsg variant constructor and the same
/// dispatch case arm, so codegen would emit two definitions of each and the
/// generated module would fail to compile. Surface as a libero-level error
/// before that happens.
fn duplicate_fn_name_errors(
  endpoints: List(HandlerEndpoint),
) -> List(GenError) {
  let by_name =
    list.fold(endpoints, dict.new(), fn(acc, ep) {
      let existing = dict.get(acc, ep.fn_name) |> result.unwrap([])
      dict.insert(acc, ep.fn_name, [ep.module_path, ..existing])
    })
  by_name
  |> dict.to_list
  |> list.filter_map(fn(pair) {
    let #(fn_name, modules_rev) = pair
    case modules_rev {
      [_, _, ..] ->
        Ok(DuplicateEndpoint(
          fn_name:,
          modules: list.reverse(modules_rev) |> list.unique,
        ))
      _ -> Error(Nil)
    }
  })
  |> list.sort(by: fn(a, b) {
    string.compare(duplicate_fn_name(a), duplicate_fn_name(b))
  })
}

fn duplicate_fn_name(err: GenError) -> String {
  case err {
    DuplicateEndpoint(fn_name:, ..) -> fn_name
    _ -> ""
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

/// Read a `.gleam` file and parse it via `glance`, surfacing both I/O and
/// parser failures as `GenError` variants tagged with the file path.
/// Shared by the handler scanner and the type walker so every codegen
/// stage produces consistent errors for the same file.
pub fn parse_module(
  file_path file_path: String,
) -> Result(glance.Module, GenError) {
  use content <- result.try(
    simplifile.read(file_path)
    |> result.map_error(fn(cause) { CannotReadFile(path: file_path, cause:) }),
  )
  glance.module(content)
  |> result.map_error(fn(cause) { ParseFailed(path: file_path, cause:) })
}

fn read_public_type_names(file_path: String) -> Result(List(String), GenError) {
  use parsed <- result.map(parse_module(file_path:))
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
  use parsed <- result.map(parse_module(file_path:))
  let module_path = derive_module_path(file_path: file_path)
  let type_imports = build_type_import_map(parsed.imports)
  let alias_map = build_alias_resolution_map(parsed.imports)
  let type_alias_originals = build_type_alias_originals(parsed.imports)
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
          type_alias_originals: type_alias_originals,
          shared_types: shared_types,
        )
    }
  })
}

/// Build a map from unqualified type names (using the alias if present)
/// to the FULL module path of their import.
/// e.g. `import shared/items.{type Item}` produces {"Item": "shared/items"}.
/// e.g. `import shared/items.{type Item as MyItem}` produces
/// {"MyItem": "shared/items"}.
/// Used by structured type resolution where downstream codegen needs the
/// full path for decoder function naming.
pub fn build_type_import_map(
  imports: List(glance.Definition(glance.Import)),
) -> dict.Dict(String, String) {
  list.fold(imports, dict.new(), fn(acc, def) {
    let glance.Definition(_, imp) = def
    list.fold(imp.unqualified_types, acc, fn(inner_acc, uq) {
      let key = case uq.alias {
        option.Some(alias) -> alias
        option.None -> uq.name
      }
      dict.insert(inner_acc, key, imp.module)
    })
  })
}

/// Map locally-bound type names back to their original names from the
/// source module. Only populated when an import uses `type X as Y`.
/// e.g. `import shared/items.{type Item as MyItem}` produces
/// {"MyItem": "Item"}. Used by `all_types_shared` so an aliased type
/// resolves against `shared_types` (which holds original names).
pub fn build_type_alias_originals(
  imports: List(glance.Definition(glance.Import)),
) -> dict.Dict(String, String) {
  list.fold(imports, dict.new(), fn(acc, def) {
    let glance.Definition(_, imp) = def
    list.fold(imp.unqualified_types, acc, fn(inner_acc, uq) {
      case uq.alias {
        option.Some(alias) -> dict.insert(inner_acc, alias, uq.name)
        option.None -> inner_acc
      }
    })
  })
}

/// Build a map from import aliases (and bare module names) to the full
/// module path. e.g. `import shared/line_items_report as wire` produces
/// {"wire": "shared/line_items_report"}. Unaliased imports produce
/// identity entries keyed by the last segment.
pub fn build_alias_resolution_map(
  imports: List(glance.Definition(glance.Import)),
) -> dict.Dict(String, String) {
  list.fold(imports, dict.new(), fn(acc, def) {
    let glance.Definition(_, imp) = def
    let last_seg = field_type.last_segment(imp.module)
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
  type_alias_originals type_alias_originals: dict.Dict(String, String),
  shared_types shared_types: set.Set(String),
) -> Result(HandlerEndpoint, Nil) {
  use #(ok_type, err_type, payload_params) <- result.try(
    validate_handler_signature(func),
  )

  // All non-builtin types must be from shared/
  let all_param_types =
    list.filter_map(payload_params, fn(p) { option.to_result(p.type_, Nil) })
  let all_types = [ok_type, err_type, ..all_param_types]
  use <- bool.guard(
    when: !all_types_shared(
      types: all_types,
      shared_types:,
      type_alias_originals:,
    ),
    return: Error(Nil),
  )

  let to_ft = fn(t) {
    glance_type_to_field_type(
      type_: t,
      imports: type_imports,
      aliases: alias_map,
      type_alias_originals: type_alias_originals,
    )
  }
  let params_typed =
    list.filter_map(payload_params, fn(p) {
      case p.label, p.type_ {
        option.Some(label), option.Some(type_) -> Ok(#(label, to_ft(type_)))
        _, _ -> Error(Nil)
      }
    })

  Ok(HandlerEndpoint(
    module_path: module_path,
    fn_name: func.name,
    return_ok: to_ft(ok_type),
    return_err: to_ft(err_type),
    params: params_typed,
  ))
}

/// Verify the function's signature matches the handler-as-contract shape:
/// at least one param, last param typed `HandlerContext`, return type
/// `#(Result(ok, err), HandlerContext)`. On success returns the two halves
/// of the `Result` and the payload parameter list (every parameter before
/// the trailing HandlerContext).
///
/// The wire envelope, dispatch, and client codecs all assume Result-shaped
/// responses; a bare value would compile but produce broken serialization
/// at runtime. Filter at scan time so codegen never sees a non-Result.
fn validate_handler_signature(
  func: glance.Function,
) -> Result(#(glance.Type, glance.Type, List(glance.FunctionParameter)), Nil) {
  let params = func.parameters
  use <- bool.guard(when: list.is_empty(params), return: Error(Nil))

  use last_param <- result.try(list.last(params))
  use last_type <- result.try(option.to_result(last_param.type_, Nil))
  use <- bool.guard(
    when: !is_handler_context_type(last_type),
    return: Error(Nil),
  )

  use return_type <- result.try(option.to_result(func.return, Nil))
  use #(response_type, _state_type) <- result.try(extract_handler_return(
    return_type,
  ))

  use #(ok_type, err_type) <- result.try(extract_result_args(response_type))

  let payload_params = list.take(params, list.length(params) - 1)
  Ok(#(ok_type, err_type, payload_params))
}

/// Check if a type annotation is the project's HandlerContext, brought
/// into local scope by an unqualified import. We deliberately reject
/// module-qualified `pkg.HandlerContext` references so that types named
/// `HandlerContext` from unrelated modules aren't treated as handler
/// endpoints.
fn is_handler_context_type(t: glance.Type) -> Bool {
  case t {
    glance.NamedType(name: "HandlerContext", module: option.None, ..) -> True
    _ -> False
  }
}

/// Pull `ok` and `err` out of a `Result(ok, err)` type annotation.
fn extract_result_args(
  t: glance.Type,
) -> Result(#(glance.Type, glance.Type), Nil) {
  case t {
    glance.NamedType(name: "Result", parameters: [ok, err], ..) ->
      Ok(#(ok, err))
    _ -> Error(Nil)
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
/// `type_alias_originals` maps locally-bound aliased type names to the
/// name they have in the source module, e.g. {"MyItem": "Item"}.
fn glance_type_to_field_type(
  type_ t: glance.Type,
  imports imports: dict.Dict(String, String),
  aliases aliases: dict.Dict(String, String),
  type_alias_originals type_alias_originals: dict.Dict(String, String),
) -> field_type.FieldType {
  let recurse_named = fn(name, params) {
    builtin_or_user(
      name:,
      parameters: params,
      imports:,
      aliases:,
      type_alias_originals:,
    )
  }
  let recurse = fn(t) {
    glance_type_to_field_type(
      type_: t,
      imports:,
      aliases:,
      type_alias_originals:,
    )
  }
  case t {
    glance.NamedType(name:, module: option.None, parameters: [], ..) ->
      recurse_named(name, [])
    glance.NamedType(name:, module: option.None, parameters: params, ..) ->
      recurse_named(name, params)
    glance.NamedType(name:, module: option.Some(m), parameters: params, ..) -> {
      let module_path = dict.get(aliases, m) |> result.unwrap(or: m)
      field_type.UserType(
        module_path:,
        type_name: name,
        args: list.map(params, recurse),
      )
    }
    glance.TupleType(elements:, ..) ->
      field_type.TupleOf(elements: list.map(elements, recurse))
    glance.VariableType(name:, ..) -> field_type.TypeVar(name:)
    glance.FunctionType(..) -> field_type.TypeVar(name: "_fn")
    glance.HoleType(..) -> field_type.TypeVar(name: "_")
  }
}

/// Resolve a non-module-qualified named type. Builtins return their
/// FieldType directly. Other names are looked up in `imports` to
/// produce a `UserType` with the import's full module path.
///
/// Invariant: callers reach this function only after
/// `all_types_shared` has accepted the name, meaning it's either a
/// builtin or a shared-tree type. If the name is in shared but not in
/// the file's imports, the handler is shadowing a shared type with a
/// local definition (only seen in test fixtures); we fall back to the
/// bare name as module_path. Production handlers always import their
/// shared types, so this fallback never fires for compiled endpoints.
fn builtin_or_user(
  name name: String,
  parameters parameters: List(glance.Type),
  imports imports: dict.Dict(String, String),
  aliases aliases: dict.Dict(String, String),
  type_alias_originals type_alias_originals: dict.Dict(String, String),
) -> field_type.FieldType {
  let recurse = fn(t) {
    glance_type_to_field_type(
      type_: t,
      imports:,
      aliases:,
      type_alias_originals:,
    )
  }
  case field_type.builtin_field_type(name:, parameters:, recurse:) {
    Ok(ft) -> ft
    Error(Nil) -> {
      let module_path = dict.get(imports, name) |> result.unwrap(or: name)
      // If the local name is an aliased import (e.g. `type Item as MyItem`),
      // the source module knows it as the original name. Use that so the
      // generated decoder calls match what the walker discovers.
      let type_name =
        dict.get(type_alias_originals, name) |> result.unwrap(or: name)
      field_type.UserType(
        module_path:,
        type_name:,
        args: list.map(parameters, recurse),
      )
    }
  }
}

/// Check that all types in a list are shared types or builtins.
/// Walks type parameters recursively (e.g. List(Todo) checks Todo).
fn all_types_shared(
  types types: List(glance.Type),
  shared_types shared_types: set.Set(String),
  type_alias_originals type_alias_originals: dict.Dict(String, String),
) -> Bool {
  list.all(types, fn(t) {
    is_type_shared(t: t, shared_types:, type_alias_originals:)
  })
}

/// Check if a single type (and all its parameters) are shared or builtins.
/// `field_type.is_builtin` is the single source of truth for builtin
/// names, shared with the walker.
///
/// Resolves locally-bound aliased type names back to their original
/// source names before checking against `shared_types`, so
/// `import shared/items.{type Item as MyItem}` lets the handler use
/// `MyItem` and still pass the shared check.
fn is_type_shared(
  t t: glance.Type,
  shared_types shared_types: set.Set(String),
  type_alias_originals type_alias_originals: dict.Dict(String, String),
) -> Bool {
  case t {
    glance.NamedType(name:, parameters:, ..) -> {
      let resolved =
        dict.get(type_alias_originals, name) |> result.unwrap(or: name)
      {
        field_type.is_builtin(resolved) || set.contains(shared_types, resolved)
      }
      && list.all(parameters, fn(p) {
        is_type_shared(t: p, shared_types:, type_alias_originals:)
      })
    }
    glance.TupleType(elements:, ..) ->
      list.all(elements, fn(e) {
        is_type_shared(t: e, shared_types:, type_alias_originals:)
      })
    glance.VariableType(..) -> True
    glance.FunctionType(parameters:, return:, ..) ->
      list.all(parameters, fn(p) {
        is_type_shared(t: p, shared_types:, type_alias_originals:)
      })
      && is_type_shared(t: return, shared_types:, type_alias_originals:)
    glance.HoleType(..) -> True
  }
}
