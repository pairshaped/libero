import glance
import gleam/bool
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import simplifile

import libero/field_type.{type FieldType, TupleOf, TypeVar, UserType}
import libero/gen_error.{
  type GenError, CannotReadFile, ParseFailed, TypeNotFound, UnresolvedTypeModule,
}
import libero/scanner

/// A custom type discovered by the walker, grouping all its variants.
pub type DiscoveredType {
  DiscoveredType(
    module_path: String,
    type_name: String,
    type_params: List(String),
    variants: List(DiscoveredVariant),
  )
}

/// A single discovered variant, used in typed decoder codegen.
pub type DiscoveredVariant {
  DiscoveredVariant(
    /// Gleam module path, e.g. "shared/discount".
    module_path: String,
    /// PascalCase constructor name, e.g. "AdminData".
    variant_name: String,
    /// snake_case atom name, e.g. "admin_data".
    atom_name: String,
    /// 0-based indices of fields whose Gleam type is Float.
    /// Used by the JS ETF encoder to distinguish Int from Float
    /// (JS erases this distinction at runtime).
    float_field_indices: List(Int),
    /// Structured types of each field, in declaration order.
    fields: List(FieldType),
  )
}

/// Maps unqualified type names and module aliases to the source module
/// path, so we can resolve `Record` → `shared/record` or
/// `record.Record` → `shared/record`.
type TypeResolver {
  TypeResolver(
    /// "Record" → "shared/record" (from `import shared/record.{type Record}`)
    unqualified: Dict(String, String),
    /// "record" → "shared/record" (from `import shared/record`, where the
    /// last segment is the alias by default)
    aliased: Dict(String, String),
    /// Maps aliased type names back to their original names.
    /// "DiscountAdminData" → "AdminData" (from `import shared/discount.{type AdminData as DiscountAdminData}`)
    /// Only populated when an alias differs from the original name.
    original_names: Dict(String, String),
  )
}

/// State threaded through the BFS type graph walker.
type WalkerState {
  WalkerState(
    queue: List(#(String, String)),
    visited: Set(#(String, String)),
    discovered: List(DiscoveredType),
    module_files: Dict(String, String),
    parsed_cache: Dict(String, glance.Module),
    errors: List(GenError),
  )
}

/// Module prefixes that should never be walked - their types are
/// handled by libero's auto-wire blocks in rpc_ffi.mjs.
const registry_skip_prefixes = ["libero/", "gleam/"]

/// Primitive/builtin type names: not custom types, never walked.
/// Sourced from `field_type.builtin_type_names` so scanner and walker
/// agree on what counts as a builtin.
/// True if a module path should not be walked by the type graph walker.
fn is_skipped_module(module_path: String) -> Bool {
  list.any(registry_skip_prefixes, fn(prefix) {
    string.starts_with(module_path, prefix)
  })
}

/// True if a type name is a primitive/builtin that needs no registration.
fn is_primitive_type(name: String) -> Bool {
  field_type.is_builtin(name)
}

/// True when a NamedType reference points to a Gleam stdlib type, not a
/// user-defined type that happens to share the name. Without this check,
/// `pub type Result` defined in shared/ would be silently dropped from
/// codegen because its name matches `registry_primitives`.
///
/// Distinguishes by module qualifier and by whether the user imported a
/// same-named type. A bare `Result` with no shadowing import is stdlib;
/// `import shared/myresult.{type Result}` makes bare `Result` user-defined.
fn is_stdlib_reference(
  name name: String,
  module module: option.Option(String),
  resolver resolver: TypeResolver,
) -> Bool {
  case is_primitive_type(name), module {
    False, _ -> False
    True, Some("gleam") -> True
    True, Some("option") -> name == "Option"
    True, Some("result") -> name == "Result"
    True, Some("dict") -> name == "Dict"
    True, Some("list") -> name == "List"
    True, Some("bool") -> name == "Bool"
    True, Some("bit_array") -> name == "BitArray"
    // Qualified with anything else: user type.
    True, Some(_) -> False
    // Unqualified primitive name: stdlib unless shadowed by a user import
    // from a non-stdlib module. `import gleam/option.{type Option}` is the
    // canonical Gleam idiom and must still resolve to the stdlib type.
    True, None ->
      case dict.get(resolver.unqualified, name) {
        Error(Nil) -> True
        Ok(module_path) -> is_stdlib_module_path(module_path)
      }
  }
}

/// True when a module path is a Gleam stdlib (or stdlib-extension) module,
/// e.g. `gleam`, `gleam/option`, `gleam/dict`. Used to decide whether an
/// unqualified primitive type name imported from that module is still the
/// stdlib type (e.g. `import gleam/option.{type Option}`) versus a user
/// type that happens to share a name with a stdlib primitive.
fn is_stdlib_module_path(path: String) -> Bool {
  path == "gleam" || string.starts_with(path, "gleam/")
}

/// Walk all exported custom types from a list of shared source files.
/// Seeds from every public type in shared/, since the codegen pipeline
/// needs decoders for any type that may appear in a handler's params or
/// return type.
pub fn walk_shared_types(
  shared_src shared_src: String,
) -> Result(List(DiscoveredType), List(GenError)) {
  // Find all .gleam files in the shared source directory.
  // Reuses scanner.walk_directory so generated/ subdirectories and
  // symlinks are skipped consistently with the rest of the pipeline.
  use files <- result.try(
    scanner.walk_directory(path: shared_src)
    |> result.map_error(fn(err) { [err] }),
  )

  // Build module_files dict
  let module_files =
    list.fold(files, dict.new(), fn(acc, file_path) {
      let module_path = derive_shared_module_path(file_path)
      dict.insert(acc, module_path, file_path)
    })

  // Seed from all exported custom types in all shared files. Surface
  // any read/parse errors instead of silently dropping them. A file
  // that fails to parse here would otherwise contribute zero seed types
  // with no warning, then later show up as TypeNotFound.
  let #(seed_set, errors_rev) =
    list.fold(files, #(set.new(), []), fn(acc, file_path) {
      let #(set_acc, errs_acc) = acc
      let module_path = derive_shared_module_path(file_path)
      case read_public_type_pairs(module_path, file_path) {
        Ok(pairs) -> #(list.fold(pairs, set_acc, set.insert), errs_acc)
        Error(err) -> #(set_acc, [err, ..errs_acc])
      }
    })
  case errors_rev {
    [] ->
      do_walk(
        WalkerState(
          queue: set.to_list(seed_set),
          visited: set.new(),
          discovered: [],
          module_files: module_files,
          parsed_cache: dict.new(),
          errors: [],
        ),
      )
    _ -> Error(list.reverse(errors_rev))
  }
}

fn read_public_type_pairs(
  module_path: String,
  file_path: String,
) -> Result(List(#(String, String)), GenError) {
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
      True -> [#(module_path, t.name), ..acc]
      False -> acc
    }
  })
}

/// Derive a module path from a shared file path. Splits on the LAST
/// `shared/src/` so vendored paths with nested `shared/src/` resolve
/// to the inner module path rather than the outermost segment.
/// e.g. "examples/checklist/shared/src/shared/items.gleam" -> "shared/items"
fn derive_shared_module_path(file_path: String) -> String {
  case string.split(file_path, "shared/src/") {
    [_only] -> string.replace(file_path, ".gleam", "")
    parts ->
      list.last(parts)
      |> result.map(fn(after) { string.replace(after, ".gleam", "") })
      |> result.unwrap(or: string.replace(file_path, ".gleam", ""))
  }
}

fn do_walk(state: WalkerState) -> Result(List(DiscoveredType), List(GenError)) {
  case state.queue {
    [] ->
      case state.errors {
        [] -> Ok(list.reverse(state.discovered))
        _ -> Error(list.reverse(state.errors))
      }
    [#(module_path, type_name), ..rest_queue] -> {
      let key = #(module_path, type_name)
      // Skip already-visited items
      use <- bool.lazy_guard(
        when: set.contains(state.visited, key),
        return: fn() { do_walk(WalkerState(..state, queue: rest_queue)) },
      )
      let state =
        WalkerState(
          ..state,
          queue: rest_queue,
          visited: set.insert(state.visited, key),
        )
      process_type(module_path:, type_name:, state:)
    }
  }
}

fn process_type(
  module_path module_path: String,
  type_name type_name: String,
  state state: WalkerState,
) -> Result(List(DiscoveredType), List(GenError)) {
  // Resolve file path - if missing, record error and continue
  case dict.get(state.module_files, module_path) {
    Error(Nil) ->
      do_walk(
        WalkerState(..state, errors: [
          UnresolvedTypeModule(module_path:, type_name:),
          ..state.errors
        ]),
      )
    Ok(file_path) ->
      process_type_file(module_path:, type_name:, file_path:, state:)
  }
}

fn process_type_file(
  module_path module_path: String,
  type_name type_name: String,
  file_path file_path: String,
  state state: WalkerState,
) -> Result(List(DiscoveredType), List(GenError)) {
  // Parse or load from cache
  case load_ast(module_path:, file_path:, parsed_cache: state.parsed_cache) {
    Error(e) -> do_walk(WalkerState(..state, errors: [e, ..state.errors]))
    Ok(#(ast, new_cache)) ->
      process_type_ast(
        module_path:,
        type_name:,
        ast:,
        state: WalkerState(..state, parsed_cache: new_cache),
      )
  }
}

fn process_type_ast(
  module_path module_path: String,
  type_name type_name: String,
  ast ast: glance.Module,
  state state: WalkerState,
) -> Result(List(DiscoveredType), List(GenError)) {
  // Type aliases are transparent: resolve the alias target and enqueue
  // any custom types found inside it. The alias itself doesn't produce
  // a DiscoveredType (it has no variants to register).
  case list.find(ast.type_aliases, fn(d) { d.definition.name == type_name }) {
    Ok(alias_def) -> {
      let resolver = build_type_resolver(ast.imports)
      let target_refs =
        collect_type_refs(
          t: alias_def.definition.aliased,
          resolver:,
          current_module: module_path,
        )
      let new_refs =
        list.filter(target_refs, fn(ref) {
          let #(ref_module, ref_type) = ref
          !set.contains(state.visited, ref)
          && !is_skipped_module(ref_module)
          && !is_primitive_type(ref_type)
        })
      do_walk(WalkerState(..state, queue: list.append(new_refs, state.queue)))
    }
    // Not an alias: find the custom type definition
    Error(Nil) ->
      process_type_ast_custom(module_path:, type_name:, ast:, state:)
  }
}

fn process_type_ast_custom(
  module_path module_path: String,
  type_name type_name: String,
  ast ast: glance.Module,
  state state: WalkerState,
) -> Result(List(DiscoveredType), List(GenError)) {
  case list.find(ast.custom_types, fn(d) { d.definition.name == type_name }) {
    Error(Nil) ->
      do_walk(
        WalkerState(..state, errors: [
          TypeNotFound(module_path:, type_name:),
          ..state.errors
        ]),
      )
    Ok(ct_def) -> {
      let custom_type = ct_def.definition
      let resolver = build_type_resolver(ast.imports)
      let aliases = build_alias_map(ast.type_aliases)
      // Collect variants and field type refs
      let #(variants_rev, new_queue_items_rev) =
        list.fold(custom_type.variants, #([], []), fn(acc, variant) {
          let #(disc_acc, queue_acc) = acc
          let float_indices = detect_float_fields(variant.fields)
          let fields =
            list.map(variant.fields, fn(field) {
              field_type_of(
                t: variant_field_type(field),
                resolver:,
                aliases:,
                current_module: module_path,
              )
            })
          let disc_item =
            DiscoveredVariant(
              module_path: module_path,
              variant_name: variant.name,
              atom_name: to_snake_case(variant.name),
              float_field_indices: float_indices,
              fields:,
            )
          let field_refs =
            collect_variant_field_refs(
              variant: variant,
              resolver: resolver,
              current_module: module_path,
              visited: state.visited,
            )
          #([disc_item, ..disc_acc], list.append(field_refs, queue_acc))
        })
      let discovered_type =
        DiscoveredType(
          module_path: module_path,
          type_name: type_name,
          type_params: custom_type.parameters,
          variants: list.reverse(variants_rev),
        )
      let new_queue_items = list.reverse(new_queue_items_rev)
      do_walk(
        WalkerState(
          ..state,
          queue: list.append(new_queue_items, state.queue),
          discovered: [discovered_type, ..state.discovered],
        ),
      )
    }
  }
}

/// Parse a module, returning the cached version if available.
fn load_ast(
  module_path module_path: String,
  file_path file_path: String,
  parsed_cache parsed_cache: Dict(String, glance.Module),
) -> Result(#(glance.Module, Dict(String, glance.Module)), GenError) {
  case dict.get(parsed_cache, module_path) {
    Ok(ast) -> Ok(#(ast, parsed_cache))
    Error(Nil) -> {
      use source <- result.try(
        simplifile.read(file_path)
        |> result.map_error(fn(cause) {
          CannotReadFile(path: file_path, cause:)
        }),
      )
      use ast <- result.map(
        glance.module(source)
        |> result.map_error(fn(cause) { ParseFailed(path: file_path, cause:) }),
      )
      #(ast, dict.insert(parsed_cache, module_path, ast))
    }
  }
}

/// Return 0-based indices of fields whose outermost type is Float.
/// Used by the JS ETF encoder to distinguish Int from Float
/// (JS erases this distinction at runtime, but ETF and BEAM need it).
fn detect_float_fields(fields: List(glance.VariantField)) -> List(Int) {
  list.index_fold(fields, [], fn(acc, field, index) {
    case is_float_type(variant_field_type(field)) {
      True -> [index, ..acc]
      False -> acc
    }
  })
  |> list.reverse
}

/// Check if a glance type is `Float` (unqualified or gleam-qualified).
fn is_float_type(t: glance.Type) -> Bool {
  case t {
    glance.NamedType(name: "Float", module: option.None, ..) -> True
    glance.NamedType(name: "Float", module: option.Some("gleam"), ..) -> True
    _ -> False
  }
}

/// Collect (module_path, type_name) refs from a variant's fields,
/// filtering out visited, skipped, and primitive refs.
fn collect_variant_field_refs(
  variant variant: glance.Variant,
  resolver resolver: TypeResolver,
  current_module current_module: String,
  visited visited: Set(#(String, String)),
) -> List(#(String, String)) {
  let field_refs =
    list.flat_map(variant.fields, fn(field) {
      collect_type_refs(
        t: variant_field_type(field),
        resolver:,
        current_module:,
      )
    })
  list.filter(field_refs, fn(ref) {
    let #(ref_module, ref_type) = ref
    !set.contains(visited, ref)
    && !is_skipped_module(ref_module)
    && !is_primitive_type(ref_type)
  })
}

/// Resolve a type name (with optional module qualifier) to its full
/// module path. Falls back to current_module when the name is unqualified
/// and not in the resolver - meaning it's defined in the current module.
fn resolve_type_module(
  name name: String,
  module module: option.Option(String),
  resolver resolver: TypeResolver,
  current_module current_module: String,
) -> Result(String, Nil) {
  case module {
    Some(alias) -> dict.get(resolver.aliased, alias)
    None ->
      case dict.get(resolver.unqualified, name) {
        Ok(mp) -> Ok(mp)
        Error(Nil) -> Ok(current_module)
      }
  }
}

/// Walk a glance.Type and return (module_path, type_name) refs for any
/// named custom types found. Uses resolver to map alias/unqualified names
/// to their full module paths. `current_module` is the module path of the
/// file being walked - used to resolve unqualified names that are defined
/// in the same file (not in any import).
fn collect_type_refs(
  t t: glance.Type,
  resolver resolver: TypeResolver,
  current_module current_module: String,
) -> List(#(String, String)) {
  case t {
    glance.NamedType(name:, module:, parameters:, ..) -> {
      // Recurse into type parameters regardless
      let param_refs =
        list.flat_map(parameters, fn(p) {
          collect_type_refs(t: p, resolver:, current_module:)
        })
      // Skip stdlib references. A primitive name alone is not enough:
      // a user-defined type named `Result` imported into the current
      // module should be walked so we emit a decoder for it.
      use <- bool.guard(
        when: is_stdlib_reference(name:, module:, resolver:),
        return: param_refs,
      )
      case
        resolve_type_module(
          name: name,
          module: module,
          resolver: resolver,
          current_module: current_module,
        )
      {
        Error(Nil) -> param_refs
        Ok(mp) -> {
          use <- bool.guard(when: is_skipped_module(mp), return: param_refs)
          // Resolve aliased type names back to original names.
          // e.g. `type AdminData as DiscountAdminData` - we need to look up
          // "AdminData" in the target module, not "DiscountAdminData".
          let original_name =
            result.unwrap(dict.get(resolver.original_names, name), name)
          list.append([#(mp, original_name)], param_refs)
        }
      }
    }
    glance.TupleType(elements:, ..) ->
      list.flat_map(elements, fn(e) {
        collect_type_refs(t: e, resolver:, current_module:)
      })
    glance.FunctionType(..) -> []
    glance.VariableType(..) -> []
    glance.HoleType(..) -> []
  }
}

/// Convert a glance.Type into a FieldType, resolving named types via the resolver.
/// Type aliases in `aliases` are resolved transparently to their underlying type.
fn field_type_of(
  t t: glance.Type,
  resolver resolver: TypeResolver,
  aliases aliases: Dict(String, glance.Type),
  current_module current_module: String,
) -> FieldType {
  case t {
    glance.VariableType(name:, ..) -> TypeVar(name:)
    glance.TupleType(elements:, ..) ->
      TupleOf(
        list.map(elements, fn(e) {
          field_type_of(t: e, resolver:, aliases:, current_module:)
        }),
      )
    // Functions and holes cannot be serialized over ETF. Mapped to TypeVar
    // which throws at runtime in the typed decoder ("TypeVar<_fn> not supported").
    // This is intentional: a build-time error would require tracking which
    // fields are transitively reachable from messages, which the walker doesn't
    // do for non-custom types. The runtime error is clear and immediate.
    glance.FunctionType(..) -> TypeVar(name: "_fn")
    glance.HoleType(..) -> TypeVar(name: "_")
    glance.NamedType(name:, module:, parameters:, ..) ->
      case is_stdlib_reference(name:, module:, resolver:) {
        True ->
          stdlib_field_type(
            name:,
            parameters:,
            resolver:,
            aliases:,
            current_module:,
          )
        False ->
          resolve_field_type(
            name:,
            module:,
            parameters:,
            resolver:,
            aliases:,
            current_module:,
          )
      }
  }
}

/// Map a stdlib NamedType reference to its FieldType. Caller must have
/// already verified via `is_stdlib_reference` that this isn't a
/// user-defined type shadowing a primitive name.
fn stdlib_field_type(
  name name: String,
  parameters parameters: List(glance.Type),
  resolver resolver: TypeResolver,
  aliases aliases: Dict(String, glance.Type),
  current_module current_module: String,
) -> FieldType {
  let recurse = fn(t) {
    field_type_of(t:, resolver:, aliases:, current_module:)
  }
  case field_type.builtin_field_type(name:, parameters:, recurse:) {
    Ok(ft) -> ft
    // Arity mismatch (e.g. bare `Result` used as a type name with zero
    // args): fall through to UserType so codegen produces a decoder
    // reference rather than a malformed primitive.
    Error(Nil) ->
      UserType(
        module_path: current_module,
        type_name: name,
        args: list.map(parameters, recurse),
      )
  }
}

/// Resolve a named type: if it's a local type alias, recurse on the aliased
/// type; otherwise produce a UserType.
fn resolve_field_type(
  name name: String,
  module module: option.Option(String),
  parameters parameters: List(glance.Type),
  resolver resolver: TypeResolver,
  aliases aliases: Dict(String, glance.Type),
  current_module current_module: String,
) -> FieldType {
  // Unqualified name matching a local type alias: resolve through it
  case module, dict.get(aliases, name) {
    option.None, Ok(aliased_type) ->
      field_type_of(t: aliased_type, resolver:, aliases:, current_module:)
    _, _ -> {
      let args =
        list.map(parameters, fn(p) {
          field_type_of(t: p, resolver:, aliases:, current_module:)
        })
      let resolved_module =
        resolve_type_module(name:, module:, resolver:, current_module:)
      let mp = result.unwrap(resolved_module, current_module)
      let original_name =
        result.unwrap(dict.get(resolver.original_names, name), name)
      UserType(module_path: mp, type_name: original_name, args:)
    }
  }
}

/// Build a map from type alias names to their underlying glance.Type.
/// Used to resolve aliases transparently in field_type_of.
fn build_alias_map(
  type_aliases: List(glance.Definition(glance.TypeAlias)),
) -> Dict(String, glance.Type) {
  list.fold(type_aliases, dict.new(), fn(acc, def) {
    dict.insert(acc, def.definition.name, def.definition.aliased)
  })
}

fn build_type_resolver(
  imports: List(glance.Definition(glance.Import)),
) -> TypeResolver {
  TypeResolver(
    unqualified: scanner.build_type_import_map(imports),
    aliased: scanner.build_alias_resolution_map(imports),
    original_names: scanner.build_type_alias_originals(imports),
  )
}

/// Convert a PascalCase variant name to snake_case for the wire atom.
/// "AdminData" → "admin_data", "One" → "one", "TwoOrMore" → "two_or_more".
/// Handles consecutive uppercase: "XMLParser" → "xml_parser".
/// Must stay aligned with `snakeCase()` in rpc_ffi.mjs.
pub fn to_snake_case(name: String) -> String {
  let graphemes = string.to_graphemes(name)
  // Build triples of (prev, current, next) so we can detect acronym
  // boundaries without random access. prev/next are "" at edges.
  let triples = build_triples(remaining: graphemes, prev: "")
  list.index_fold(triples, "", fn(acc, triple, i) {
    let #(prev, g, next) = triple
    case i == 0, is_upper_grapheme(g) {
      True, _ -> acc <> string.lowercase(g)
      False, True -> {
        let prev_upper = is_upper_grapheme(prev)
        let next_lower = next != "" && !is_upper_grapheme(next)
        case prev_upper, next_lower {
          // UPPER→UPPER→lower: start of new word after acronym
          True, True -> acc <> "_" <> string.lowercase(g)
          // UPPER→UPPER→(UPPER|end): still in acronym, no separator
          True, False -> acc <> string.lowercase(g)
          // lower→UPPER: normal camelCase boundary
          _, _ -> acc <> "_" <> string.lowercase(g)
        }
      }
      False, False -> acc <> g
    }
  })
}

fn build_triples(
  remaining remaining: List(String),
  prev prev: String,
) -> List(#(String, String, String)) {
  case remaining {
    [] -> []
    [g] -> [#(prev, g, "")]
    [g, next, ..rest] -> [
      #(prev, g, next),
      ..build_triples(remaining: [next, ..rest], prev: g)
    ]
  }
}

fn is_upper_grapheme(g: String) -> Bool {
  g != string.lowercase(g)
}

/// Extract the type from a variant field, whether labelled or unlabelled.
fn variant_field_type(field: glance.VariantField) -> glance.Type {
  case field {
    glance.LabelledVariantField(item:, ..) -> item
    glance.UnlabelledVariantField(item:) -> item
  }
}
