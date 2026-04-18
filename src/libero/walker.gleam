import glance
import gleam/bool
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import simplifile

import libero/gen_error.{
  type GenError, CannotReadFile, ParseFailed, TypeNotFound, UnresolvedTypeModule,
}
import libero/scanner.{type MessageModule}

/// The Gleam type of a single variant field, resolved to a structured form.
pub type FieldType {
  UserType(module_path: String, type_name: String, args: List(FieldType))
  ListOf(element: FieldType)
  OptionOf(inner: FieldType)
  ResultOf(ok: FieldType, err: FieldType)
  DictOf(key: FieldType, value: FieldType)
  TupleOf(elements: List(FieldType))
  IntField
  FloatField
  StringField
  BoolField
  BitArrayField
  NilField
  TypeVar(name: String)
}

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

/// Primitive/builtin type names - not custom types, never walked.
const registry_primitives = [
  "Int", "Float", "String", "Bool", "Nil", "BitArray", "List", "Result",
  "Option", "Dict",
]

/// True if a module path should not be walked by the type graph walker.
fn is_skipped_module(module_path: String) -> Bool {
  list.any(registry_skip_prefixes, fn(prefix) {
    string.starts_with(module_path, prefix)
  })
}

/// True if a type name is a primitive/builtin that needs no registration.
fn is_primitive_type(name: String) -> Bool {
  list.contains(registry_primitives, name)
}

/// Walk the type graph rooted at MsgFromClient/MsgFromServer message types.
/// Seeds the BFS walker from all variants of MsgFromClient and MsgFromServer custom
/// types in each message module, then walks their field types transitively.
///
/// Both the MsgFromClient/MsgFromServer types themselves (and their constructors) and
/// all transitively reachable types are included in the discovered list,
/// since they all need codec registration.
pub fn walk_message_registry_types(
  message_modules message_modules: List(MessageModule),
  module_files module_files: Dict(String, String),
) -> Result(List(DiscoveredType), List(GenError)) {
  // Seed the work queue from MsgFromClient and MsgFromServer types in each message module.
  // We also need to seed the walk with the MsgFromClient/MsgFromServer type names
  // themselves so their variants get discovered.
  let seed =
    list.fold(message_modules, set.new(), fn(acc, message_module) {
      use <- bool.guard(
        when: is_skipped_module(message_module.module_path),
        return: acc,
      )
      let with_msg_from_client = case message_module.has_msg_from_client {
        True -> set.insert(acc, #(message_module.module_path, "MsgFromClient"))
        False -> acc
      }
      case message_module.has_msg_from_server {
        True ->
          set.insert(with_msg_from_client, #(
            message_module.module_path,
            "MsgFromServer",
          ))
        False -> with_msg_from_client
      }
    })
    |> set.to_list

  do_walk(
    WalkerState(
      queue: seed,
      visited: set.new(),
      discovered: [],
      module_files: module_files,
      parsed_cache: dict.new(),
      errors: [],
    ),
  )
}

fn do_walk(
  state: WalkerState,
) -> Result(List(DiscoveredType), List(GenError)) {
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
  // Check type alias - skip silently
  let is_alias =
    list.any(ast.type_aliases, fn(d) { d.definition.name == type_name })
  use <- bool.lazy_guard(when: is_alias, return: fn() { do_walk(state) })
  // Find the custom type definition
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
      // Collect variants and field type refs
      let #(variants_rev, new_queue_items_rev) =
        list.fold(custom_type.variants, #([], []), fn(acc, variant) {
          let #(disc_acc, queue_acc) = acc
          let float_indices = detect_float_fields(variant.fields)
          let fields =
            list.map(variant.fields, fn(field) {
              let field_type = case field {
                glance.LabelledVariantField(item:, ..) -> item
                glance.UnlabelledVariantField(item:) -> item
              }
              field_type_of(t: field_type, resolver:, current_module: module_path)
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
          queue: list.append(state.queue, new_queue_items),
          discovered: list.append(state.discovered, [discovered_type]),
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
    let field_type = case field {
      glance.LabelledVariantField(item:, ..) -> item
      glance.UnlabelledVariantField(item:) -> item
    }
    case is_float_type(field_type) {
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
      let field_type = case field {
        glance.LabelledVariantField(item:, ..) -> item
        glance.UnlabelledVariantField(item:) -> item
      }
      collect_type_refs(t: field_type, resolver:, current_module:)
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

/// Unwrap a Result, returning the default on Error or continuing with the Ok value.
fn result_guard(
  over r: Result(a, Nil),
  default default: c,
  next next: fn(a) -> c,
) -> c {
  case r {
    Ok(value) -> next(value)
    Error(Nil) -> default
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
      // Skip primitives/builtins
      use <- bool.guard(when: is_primitive_type(name), return: param_refs)
      // Resolve the module path
      let module_path =
        resolve_type_module(
          name: name,
          module: module,
          resolver: resolver,
          current_module: current_module,
        )
      use mp <- result_guard(module_path, param_refs)
      use <- bool.guard(when: is_skipped_module(mp), return: param_refs)
      // Resolve aliased type names back to original names.
      // e.g. `type AdminData as DiscountAdminData` - we need to look up
      // "AdminData" in the target module, not "DiscountAdminData".
      let original_name =
        result.unwrap(dict.get(resolver.original_names, name), name)
      list.append([#(mp, original_name)], param_refs)
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
fn field_type_of(
  t t: glance.Type,
  resolver resolver: TypeResolver,
  current_module current_module: String,
) -> FieldType {
  case t {
    glance.VariableType(name:, ..) -> TypeVar(name:)
    glance.TupleType(elements:, ..) ->
      TupleOf(list.map(elements, fn(e) {
        field_type_of(t: e, resolver:, current_module:)
      }))
    glance.FunctionType(..) -> TypeVar(name: "_fn")
    glance.HoleType(..) -> TypeVar(name: "_")
    glance.NamedType(name:, module:, parameters:, ..) ->
      case module, name, parameters {
        // Primitives - no module qualifier needed
        option.None, "Int", [] -> IntField
        option.None, "Float", [] -> FloatField
        option.None, "String", [] -> StringField
        option.None, "Bool", [] -> BoolField
        option.None, "BitArray", [] -> BitArrayField
        option.None, "Nil", [] -> NilField
        // List
        option.None, "List", [elem] ->
          ListOf(field_type_of(t: elem, resolver:, current_module:))
        // Option (gleam/option)
        option.None, "Option", [inner] ->
          OptionOf(field_type_of(t: inner, resolver:, current_module:))
        // Result
        option.None, "Result", [ok, err] ->
          ResultOf(
            ok: field_type_of(t: ok, resolver:, current_module:),
            err: field_type_of(t: err, resolver:, current_module:),
          )
        // Dict
        option.None, "Dict", [key, value] ->
          DictOf(
            key: field_type_of(t: key, resolver:, current_module:),
            value: field_type_of(t: value, resolver:, current_module:),
          )
        // Everything else: resolve to a UserType
        _, _, _ -> {
          let args =
            list.map(parameters, fn(p) {
              field_type_of(t: p, resolver:, current_module:)
            })
          let resolved_module =
            resolve_type_module(
              name: name,
              module: module,
              resolver: resolver,
              current_module: current_module,
            )
          let mp = result.unwrap(resolved_module, current_module)
          let original_name =
            result.unwrap(dict.get(resolver.original_names, name), name)
          UserType(module_path: mp, type_name: original_name, args:)
        }
      }
  }
}

fn build_type_resolver(
  imports: List(glance.Definition(glance.Import)),
) -> TypeResolver {
  let empty_unq: Dict(String, String) = dict.new()
  let empty_al: Dict(String, String) = dict.new()
  let empty_orig: Dict(String, String) = dict.new()
  let init =
    TypeResolver(
      unqualified: empty_unq,
      aliased: empty_al,
      original_names: empty_orig,
    )
  list.fold(imports, init, fn(acc, def) {
    let imp = def.definition
    let module_path = imp.module
    // Unqualified types: `import foo.{type Bar}` → "Bar" -> module_path
    // Also track aliases: `import foo.{type Bar as Baz}` → "Baz" -> module_path
    // and original_names: "Baz" → "Bar"
    let acc =
      list.fold(imp.unqualified_types, acc, fn(acc, uq) {
        let name = case uq.alias {
          Some(a) -> a
          None -> uq.name
        }
        let new_originals = case uq.alias {
          Some(_a) -> dict.insert(acc.original_names, name, uq.name)
          None -> acc.original_names
        }
        TypeResolver(
          unqualified: dict.insert(acc.unqualified, name, module_path),
          aliased: acc.aliased,
          original_names: new_originals,
        )
      })
    // Module alias: `import shared/record` → "record" -> "shared/record"
    let alias_name = case imp.alias {
      Some(glance.Named(name)) -> name
      _ -> default_module_alias(module_path)
    }
    TypeResolver(
      ..acc,
      aliased: dict.insert(acc.aliased, alias_name, module_path),
    )
  })
}

fn default_module_alias(module_path: String) -> String {
  string.split(module_path, "/")
  |> list.last
  |> result.unwrap(module_path)
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
