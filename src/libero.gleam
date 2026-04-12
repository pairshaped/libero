//// RPC dispatch and client stub generator.
////
//// Scans `server/src/server/**/*.gleam` for `pub fn`s marked with a
//// `/// @rpc` doc comment and produces:
////
////   1. `client/src/client/rpc/<module>.gleam`, per-module labeled
////      stub functions that look like ordinary Gleam functions to the
////      client developer. Each stub takes the same labels as the server
////      function (minus the first "session context" param) plus an
////      `on_response` callback, and returns `Effect(msg)`.
////
////   2. `server/src/server/rpc_dispatch_generated.gleam`, a flat case
////      expression that receives a decoded call envelope, looks up the
////      function by wire name, coerces the positional args, and calls
////      the real server function with the session context prepended.
////
//// ## Conventions
////
//// - The first parameter of an @rpc function is the session context
////   (e.g. `sqlight.Connection`) and is injected from the dispatch's
////   `db` argument. It is NOT part of the wire args.
////
//// - The wire name is derived from the server file path and function
////   name: `server/src/server/records.gleam` + `save` → `"records.save"`.
////   Nested modules work: `server/src/server/admin/items.gleam` + `create`
////   → `"admin.items.create"`.
////
//// - Types in parameter positions and return types should be reachable
////   from the generated stub (i.e. from a shared package). The generator
////   walks the server file's imports to resolve unqualified type names
////   and emits matching imports in the stub.
////
//// - Doc comments are discarded by glance, so `/// @rpc` is found by
////   preprocessing the source text to build a set of annotated function
////   names, then each function's signature is extracted via glance.

import argv
import glance
import gleam/bool
import gleam/dict.{type Dict}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import simplifile

// ---------- Paths ----------
//
// All paths are relative to the CWD when the generator is invoked.
// The expected invocation is:
//
//     cd <consumer>/server && gleam run -m libero -- --ws-url=...
//
// ...from inside a project whose server and client packages are
// siblings (server/, client/, optionally shared/). The actual
// directories libero scans and writes are derived on Config from
// --namespace and --client; see build_config below.

// Files within the scan root that should NOT be scanned for @rpc fns.
// Libero's own generated output lives under `generated/` subdirs
// which the recursive scanner skips by convention, so no entry is needed
// here for dispatch or stub files.
//
// sql.gleam is parrot's output. It has no @rpc annotations so the
// annotation filter would exclude it anyway, but it can grow into a
// large generated file that would slow down glance parsing on every
// scan. Skip it explicitly until parrot's --output-dir flag lets
// projects move it under generated/parrot/.
const scan_excludes = [
  "sql.gleam",
]

// ---------- Inject map ----------

/// A single /// @inject function, used to substitute values into
/// @rpc dispatch calls.
type InjectFn {
  InjectFn(
    /// Function name (also the label it matches on @rpc params).
    name: String,
    /// Module path to import, e.g. "server/rpc_inject".
    module_path: String,
    /// Alias used to qualify the call, e.g. "rpc_inject".
    module_alias: String,
  )
}

/// Session context discovered from @inject functions. All @inject fns
/// must take the same type as their first parameter. That type becomes
/// the dispatch function's session parameter type.
type SessionInfo {
  SessionInfo(
    /// Rendered type string, e.g. "session.Session".
    type_rendered: String,
    /// Imports needed to reference the session type.
    imports: ImportMap,
  )
}

/// The full injection map: label → InjectFn.
type InjectMap =
  Dict(String, InjectFn)

// ---------- Types ----------

/// A resolved RPC function extracted from a server source file.
type Rpc {
  Rpc(
    /// Wire name, e.g. "records.save"
    wire_name: String,
    /// Last segment of the wire name, e.g. "save", used as the stub
    /// function name.
    fn_name: String,
    /// Path used to import the server module, e.g. "server/records".
    server_module: String,
    /// Module alias to use in the dispatch call, e.g. "records".
    server_module_alias: String,
    /// File path the stub should be written to, relative to the
    /// generator's cwd.
    client_stub_path: String,
    /// Server function params in order, classified as either injected
    /// from the session or carried on the wire. The dispatch substitutes
    /// inject_module.inject_fn(session) for injected params and coerces
    /// wire params from List(Dynamic). The stub only exposes wire params
    /// in its signature.
    all_params: List(ClassifiedParam),
    /// Convenience: wire params only, for stub rendering.
    wire_params: List(Param),
    /// The shape of the server function's return type, either a bare
    /// `T` or an explicit `Result(T, E)`. Drives dispatch unwrapping
    /// and stub type parameterization.
    return_shape: ReturnShape,
    /// Imports the stub file needs to reference parameter and return
    /// types. Keys are module paths; values are the set of type names
    /// to bring in unqualified. An empty value set means "import the
    /// module for qualified access, no unqualified types".
    ///
    /// Grouped by module so multiple types from the same package
    /// merge into a single `import foo.{type A, type B}` line.
    stub_imports: Dict(String, Set(String)),
  )
}

type Param {
  Param(label: String, rendered_type: String)
}

/// A server function parameter classified by whether it's injected
/// from the session or carried on the wire.
type ClassifiedParam {
  /// An injected param: dispatch will call the inject fn; stub hides it.
  Injected(label: String, inject: InjectFn)
  /// A wire param: appears in the stub and is coerced from Dynamic.
  Wire(param: Param)
}

/// What the server function returns and how the stub should type its
/// `on_response` callback.
type ReturnShape {
  /// Server returns a bare `T`. The stub's response type is
  /// `Result(T, RpcError(Never))`, with no AppError arm possible.
  Bare(ok_rendered: String)
  /// Server returns `Result(T, E)`. The stub's response type is
  /// `Result(T, RpcError(E))`, where E is the app's error type.
  Wrapped(ok_rendered: String, err_rendered: String)
}

// ---------- Errors ----------

type GenError {
  CannotReadDir(path: String, cause: simplifile.FileError)
  CannotReadFile(path: String, cause: simplifile.FileError)
  CannotWriteFile(path: String, cause: simplifile.FileError)
  ParseFailed(path: String, cause: glance.Error)
  NoContextParam(path: String, fn_name: String)
  NoReturnType(path: String, fn_name: String)
  UnlabelledParam(path: String, fn_name: String, position: Int)
  UnknownType(path: String, fn_name: String, type_name: String)
  DuplicateWireName(wire_name: String)
  EmptyModulePath(path: String)
  UnresolvedTypeModule(module_path: String, type_name: String)
  TypeNotFound(module_path: String, type_name: String)
}

// ---------- CLI configuration ----------

/// Everything libero needs from its invocation args, normalized.
/// Paths are derived from --namespace and --client with single-SPA
/// defaults when those flags are absent.
type Config {
  Config(
    ws_url: String,
    namespace: option.Option(String),
    client_root: String,
    scan_root: String,
    dispatch_output: String,
    stub_root: String,
    config_output: String,
    register_gleam_output: String,
    register_ffi_output: String,
    /// Bundle-relative prefix that prepends every import in the
    /// generated FFI .mjs file. Depth depends on where the register
    /// files land inside the consumer client package.
    register_relpath_prefix: String,
  )
}

fn parse_config() -> Config {
  let args = argv.load().arguments
  case find_flag(args: args, name: "--ws-url") {
    Ok(ws_url) -> {
      let namespace = case find_flag(args: args, name: "--namespace") {
        Ok(ns) -> Some(ns)
        Error(Nil) -> None
      }
      let client_root = case find_flag(args: args, name: "--client") {
        Ok(path) -> path
        Error(Nil) -> "../client"
      }
      build_config(
        ws_url: ws_url,
        namespace: namespace,
        client_root: client_root,
      )
    }
    Error(Nil) -> {
      io.println_error("error: --ws-url is required")
      io.println_error("")
      io.println_error(
        "  Libero generates a client rpc_config with this URL baked in at",
      )
      io.println_error(
        "  compile time. There is no default. Pass --ws-url=wss://<host>/ws/rpc",
      )
      io.println_error("  for your environment.")
      io.println_error("")
      io.println_error("  Example:")
      io.println_error(
        "    gleam run -m libero -- --ws-url=wss://example.com/admin/ws/rpc --namespace=admin",
      )
      let _halt = halt(1)
      // Unreachable: halt/1 terminates the process via Erlang's
      // erlang:halt/1 external. This line exists only because Gleam's
      // type checker can't see through the external's `-> Nil` return
      // type to know control never reaches here.
      build_config(ws_url: "", namespace: None, client_root: "../client")
    }
  }
}

/// Derive all paths from --namespace and --client. When namespace is
/// None the paths land under generated/libero/ inside the consumer's
/// server and client packages. When set, paths are nested one level
/// deeper under generated/libero/<namespace>/ to keep multi-SPA output
/// physically isolated.
fn build_config(
  ws_url ws_url: String,
  namespace namespace: option.Option(String),
  client_root client_root: String,
) -> Config {
  // In the final JS bundle, registration files land at:
  //   <bundle_root>/<client_pkg>/client/generated/libero/[<ns>/]rpc_register_ffi.mjs
  // So from the ffi file's directory, the bundle root is:
  //   - 4 levels up for no-namespace (client_pkg/client/generated/libero/)
  //   - 5 levels up for namespaced  (client_pkg/client/generated/libero/<ns>/)
  let #(
    scan_root,
    dispatch_output,
    stub_root,
    config_output,
    register_gleam_output,
    register_ffi_output,
    register_relpath_prefix,
  ) = case namespace {
    None -> #(
      "src/server",
      "src/server/generated/libero/rpc_dispatch.gleam",
      client_root <> "/src/client/generated/libero/rpc",
      client_root <> "/src/client/generated/libero/rpc_config.gleam",
      client_root <> "/src/client/generated/libero/rpc_register.gleam",
      client_root <> "/src/client/generated/libero/rpc_register_ffi.mjs",
      "../../../../",
    )
    Some(ns) -> #(
      "src/server/" <> ns,
      "src/server/generated/libero/" <> ns <> "/rpc_dispatch.gleam",
      client_root <> "/src/client/generated/libero/" <> ns <> "/rpc",
      client_root
        <> "/src/client/generated/libero/"
        <> ns
        <> "/rpc_config.gleam",
      client_root
        <> "/src/client/generated/libero/"
        <> ns
        <> "/rpc_register.gleam",
      client_root
        <> "/src/client/generated/libero/"
        <> ns
        <> "/rpc_register_ffi.mjs",
      "../../../../../",
    )
  }
  Config(
    ws_url: ws_url,
    namespace: namespace,
    client_root: client_root,
    scan_root: scan_root,
    dispatch_output: dispatch_output,
    stub_root: stub_root,
    config_output: config_output,
    register_gleam_output: register_gleam_output,
    register_ffi_output: register_ffi_output,
    register_relpath_prefix: register_relpath_prefix,
  )
}

/// Extract a `--name=value` flag from the argument list.
fn find_flag(args args: List(String), name name: String) -> Result(String, Nil) {
  let prefix = name <> "="
  args
  |> list.find(fn(arg) { string.starts_with(arg, prefix) })
  |> result.map(fn(arg) { string.drop_start(arg, string.length(prefix)) })
}

// ---------- Entry point ----------

pub fn main() -> Nil {
  let config = parse_config()
  io.println("libero: scanning " <> config.scan_root)

  case run(config) {
    Ok(count) -> {
      io.println(
        "libero: done. generated " <> int.to_string(count) <> " RPC stubs",
      )
    }
    Error(errors) -> {
      list.each(errors, print_error)
      let count = int.to_string(list.length(errors))
      io.println_error("")
      io.println_error("libero: " <> count <> " error(s), no files generated")
      let _halt = halt(1)
    }
  }
}

/// Runs the whole pipeline. Returns Ok(count) on success with the
/// number of RPCs written, or Error(errors) with every problem we
/// found, not just the first, so users see all issues in one run.
fn run(config: Config) -> Result(Int, List(GenError)) {
  use source_files <- result.try(
    discover_source_files(config: config)
    |> result.map_error(fn(e) { [e] }),
  )
  io.println(
    "libero: found "
    <> int.to_string(list.length(source_files))
    <> " server source files",
  )

  // Pass 1: scan all files for /// @inject functions. Build the
  // injection map and infer the session type.
  use #(inject_map, session) <- result.try(build_inject_map(
    source_files: source_files,
    config: config,
  ))
  io.println(
    "libero: found "
    <> int.to_string(dict.size(inject_map))
    <> " @inject functions",
  )

  // Pass 2: extract @rpc functions from each file, using the inject
  // map to partition params.
  let #(all_rpcs, extraction_errors) =
    list.fold(source_files, #([], []), fn(acc, path) {
      let #(rpcs_so_far, errors_so_far) = acc
      case
        extract_rpcs_from_file(
          path: path,
          inject_map: inject_map,
          config: config,
        )
      {
        Ok(rpcs) -> #(list.append(rpcs_so_far, rpcs), errors_so_far)
        Error(errors) -> #(rpcs_so_far, list.append(errors_so_far, errors))
      }
    })

  // Check for duplicate wire names across all files.
  let dup_errors = find_duplicate_wire_names(rpcs: all_rpcs)

  let all_errors = list.append(extraction_errors, dup_errors)
  case all_errors {
    [] -> {
      io.println(
        "libero: extracted "
        <> int.to_string(list.length(all_rpcs))
        <> " @rpc functions",
      )
      use _ <- result.try(
        write_stub_files(rpcs: all_rpcs, config: config)
        |> result.map_error(fn(e) { [e] }),
      )
      use _ <- result.try(
        write_dispatch(
          rpcs: all_rpcs,
          inject_map: inject_map,
          session: session,
          config: config,
        )
        |> result.map_error(fn(e) { [e] }),
      )
      use _ <- result.try(
        write_config(config: config) |> result.map_error(fn(e) { [e] }),
      )
      use _ <- result.try(
        write_register(config: config, rpcs: all_rpcs)
        |> result.map_error(fn(errors) { errors }),
      )
      Ok(list.length(all_rpcs))
    }
    _ -> Error(all_errors)
  }
}

fn find_duplicate_wire_names(rpcs rpcs: List(Rpc)) -> List(GenError) {
  // Group RPCs by wire name; any group with >1 member is a dup.
  let by_name: Dict(String, List(Rpc)) =
    list.fold(rpcs, dict.new(), fn(acc, rpc) {
      let existing =
        dict.get(acc, rpc.wire_name)
        |> result.unwrap([])
      dict.insert(acc, rpc.wire_name, [rpc, ..existing])
    })
  dict.fold(by_name, [], fn(acc, name, group) {
    case group {
      [_first, _second, ..] -> [DuplicateWireName(wire_name: name), ..acc]
      _ -> acc
    }
  })
}

fn print_error(err: GenError) -> Nil {
  let message = case err {
    CannotReadDir(path, cause) ->
      "cannot read directory: "
      <> path
      <> " ("
      <> format_file_error(cause)
      <> ")"
    CannotReadFile(path, cause) ->
      "cannot read file: " <> path <> " (" <> format_file_error(cause) <> ")"
    CannotWriteFile(path, cause) ->
      "cannot write file: " <> path <> " (" <> format_file_error(cause) <> ")"
    ParseFailed(path, _cause) ->
      path <> ": failed to parse as Gleam source (glance.module error)"
    EmptyModulePath(path) ->
      path <> ": could not derive module segments (path produced empty list)"
    NoContextParam(path, fn_name) ->
      path
      <> ": @rpc function `"
      <> fn_name
      <> "` has no parameters. The first parameter must be the session context"
      <> "\n  e.g. `pub fn "
      <> fn_name
      <> "(conn conn: sqlight.Connection, ...) -> ...`"
    NoReturnType(path, fn_name) ->
      path
      <> ": @rpc function `"
      <> fn_name
      <> "` has no return type annotation"
      <> "\n  every @rpc function must explicitly annotate its return type"
    UnlabelledParam(path, fn_name, position) ->
      path
      <> ": @rpc function `"
      <> fn_name
      <> "` parameter at position "
      <> int.to_string(position)
      <> " has no label"
      <> "\n  @rpc parameters must be labelled: `name name: String`"
    UnknownType(path, fn_name, type_name) ->
      path
      <> ": @rpc function `"
      <> fn_name
      <> "` references type `"
      <> type_name
      <> "` which isn't imported in this file"
      <> "\n  add an `import shared/<module>.{type "
      <> type_name
      <> "}` to "
      <> path
    DuplicateWireName(wire_name) ->
      "duplicate wire name: two @rpc functions both resolve to `"
      <> wire_name
      <> "`"
      <> "\n  rename one of them, or use an explicit `/// @rpc other.name` override (not yet implemented)"
    UnresolvedTypeModule(module_path, type_name) ->
      "type `"
      <> type_name
      <> "` from module `"
      <> module_path
      <> "` could not be resolved to a file path"
      <> "\n  ensure the module is in a path dep of the client package"
    TypeNotFound(module_path, type_name) ->
      "type `"
      <> type_name
      <> "` was not found in module `"
      <> module_path
      <> "`"
      <> "\n  the type may be private, or the module path may be incorrect"
  }
  io.println_error("error: " <> message)
}

fn format_file_error(err: simplifile.FileError) -> String {
  simplifile.describe_error(err)
}

@external(erlang, "erlang", "halt")
fn halt(code: Int) -> Nil

// ---------- Config file ----------

fn write_config(config config: Config) -> Result(Nil, GenError) {
  let content =
    "//// Code generated by libero. DO NOT EDIT.
////
//// WebSocket URL passed to libero at generation time via --ws-url.
//// Rerun bin/dev to regenerate if the URL changes.

pub const ws_url: String = \"" <> config.ws_url <> "\"
"
  let output = config.config_output
  ensure_parent_dir(path: output)
  case simplifile.write(output, content) {
    Ok(_) -> {
      io.println("  wrote " <> output)
      Ok(Nil)
    }
    Error(cause) -> Error(CannotWriteFile(path: output, cause: cause))
  }
}

// ---------- Type registration codegen ----------
//
// Consumer custom types (records, sum types) cross the wire as tagged
// objects like `{"@": "admin_data", "v": [...]}`. On the client, libero's
// rebuild function needs a Map<string, Constructor> to reconstruct each
// tag into an instance of the Gleam-compiled JS class.
//
// Gleam's runtime on Erlang can introspect custom types via
// `erlang:atom_to_binary`, but JS has no such reflection. So libero
// emits a per-namespace registration file that registers every consumer
// constructor referenced transitively from @rpc signatures.
//
// The walker starts from the types referenced in each @rpc stub_imports
// dict, then walks each custom type's variant fields transitively to
// discover all types that can appear on the wire. Only path deps of the
// client package are walked — hex deps (gleam_stdlib etc.) are skipped
// because their types are handled by the auto-wire block in rpc_ffi.mjs.

/// Single path dependency from a gleam.toml file, e.g.
/// `shared = { path = "../shared" }`.
type PathDep {
  PathDep(name: String, path: String)
}

/// A single discovered variant to emit as a registerConstructor call.
type DiscoveredVariant {
  DiscoveredVariant(
    /// Gleam module path, e.g. "shared/discount".
    module_path: String,
    /// PascalCase constructor name, e.g. "AdminData".
    variant_name: String,
    /// snake_case atom name, e.g. "admin_data".
    atom_name: String,
  )
}

/// Module prefixes that should never be walked — their types are
/// handled by libero's auto-wire blocks in rpc_ffi.mjs.
const registry_skip_prefixes = ["libero/", "gleam/"]

/// Primitive/builtin type names — not custom types, never walked.
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

/// Build module_path → file_path entries for one path dep's src/ directory.
fn merge_dep_module_files(
  acc acc: Dict(String, String),
  dep dep: PathDep,
) -> Dict(String, String) {
  let src_root = dep.path <> "/src"
  let files = walk_directory(path: src_root) |> result.unwrap([])
  list.fold(files, acc, fn(acc2, file) {
    let prefix = src_root <> "/"
    use <- bool.guard(when: !string.starts_with(file, prefix), return: acc2)
    let relative = string.drop_start(file, string.length(prefix))
    use <- bool.guard(
      when: !string.ends_with(relative, ".gleam"),
      return: acc2,
    )
    let module_path = string.drop_end(relative, string.length(".gleam"))
    dict.insert(acc2, module_path, file)
  })
}

/// Walk the type graph rooted at the types referenced in @rpc signatures.
/// Returns the list of all variants that need to be registered, in
/// discovery order (suitable for deterministic emission).
fn walk_registry_types(
  rpcs rpcs: List(Rpc),
  path_deps path_deps: List(PathDep),
) -> Result(List(DiscoveredVariant), List(GenError)) {
  // Build module_files: Dict(module_path, file_path) from all path deps.
  let module_files =
    list.fold(path_deps, dict.new(), fn(acc, dep) {
      merge_dep_module_files(acc: acc, dep: dep)
    })

  // Seed the work queue from all stub_imports across all RPCs,
  // filtering out skipped and primitive types.
  let seed =
    list.fold(rpcs, set.new(), fn(acc, rpc) {
      dict.fold(rpc.stub_imports, acc, fn(acc2, module_path, type_names) {
        use <- bool.guard(
          when: is_skipped_module(module_path),
          return: acc2,
        )
        set.fold(type_names, acc2, fn(acc3, type_name) {
          use <- bool.guard(
            when: is_primitive_type(type_name),
            return: acc3,
          )
          set.insert(acc3, #(module_path, type_name))
        })
      })
    })
    |> set.to_list

  // Run the BFS walk.
  do_walk(
    queue: seed,
    visited: set.new(),
    discovered: [],
    module_files: module_files,
    parsed_cache: dict.new(),
    errors: [],
  )
}

fn do_walk(
  queue queue: List(#(String, String)),
  visited visited: Set(#(String, String)),
  discovered discovered: List(DiscoveredVariant),
  module_files module_files: Dict(String, String),
  parsed_cache parsed_cache: Dict(String, glance.Module),
  errors errors: List(GenError),
) -> Result(List(DiscoveredVariant), List(GenError)) {
  case queue {
    [] ->
      case errors {
        [] -> Ok(list.reverse(discovered))
        _ -> Error(errors)
      }
    [#(module_path, type_name), ..rest_queue] -> {
      let key = #(module_path, type_name)
      // Skip already-visited items
      use <- bool.guard(
        when: set.contains(visited, key),
        return: do_walk(
          queue: rest_queue,
          visited: visited,
          discovered: discovered,
          module_files: module_files,
          parsed_cache: parsed_cache,
          errors: errors,
        ),
      )
      let new_visited = set.insert(visited, key)
      process_type(
        module_path: module_path,
        type_name: type_name,
        rest_queue: rest_queue,
        visited: new_visited,
        discovered: discovered,
        module_files: module_files,
        parsed_cache: parsed_cache,
        errors: errors,
      )
    }
  }
}

fn process_type(
  module_path module_path: String,
  type_name type_name: String,
  rest_queue rest_queue: List(#(String, String)),
  visited visited: Set(#(String, String)),
  discovered discovered: List(DiscoveredVariant),
  module_files module_files: Dict(String, String),
  parsed_cache parsed_cache: Dict(String, glance.Module),
  errors errors: List(GenError),
) -> Result(List(DiscoveredVariant), List(GenError)) {
  let continue_without_errors = fn(cache) {
    do_walk(
      queue: rest_queue,
      visited: visited,
      discovered: discovered,
      module_files: module_files,
      parsed_cache: cache,
      errors: errors,
    )
  }
  let continue_with_error = fn(cache, e) {
    do_walk(
      queue: rest_queue,
      visited: visited,
      discovered: discovered,
      module_files: module_files,
      parsed_cache: cache,
      errors: list.append(errors, [e]),
    )
  }
  // Resolve file path — if missing, record error and continue
  case dict.get(module_files, module_path) {
    Error(Nil) ->
      continue_with_error(
        parsed_cache,
        UnresolvedTypeModule(module_path:, type_name:),
      )
    Ok(file_path) ->
      process_type_file(
        module_path: module_path,
        type_name: type_name,
        file_path: file_path,
        rest_queue: rest_queue,
        visited: visited,
        discovered: discovered,
        module_files: module_files,
        parsed_cache: parsed_cache,
        errors: errors,
        continue_without_errors: continue_without_errors,
        continue_with_error: continue_with_error,
      )
  }
}

fn process_type_file(
  module_path module_path: String,
  type_name type_name: String,
  file_path file_path: String,
  rest_queue rest_queue: List(#(String, String)),
  visited visited: Set(#(String, String)),
  discovered discovered: List(DiscoveredVariant),
  module_files module_files: Dict(String, String),
  parsed_cache parsed_cache: Dict(String, glance.Module),
  errors errors: List(GenError),
  continue_without_errors continue_without_errors: fn(Dict(String, glance.Module)) ->
    Result(List(DiscoveredVariant), List(GenError)),
  continue_with_error continue_with_error: fn(
    Dict(String, glance.Module),
    GenError,
  ) ->
    Result(List(DiscoveredVariant), List(GenError)),
) -> Result(List(DiscoveredVariant), List(GenError)) {
  // Parse or load from cache
  case load_ast(module_path:, file_path:, parsed_cache:) {
    Error(e) -> continue_with_error(parsed_cache, e)
    Ok(#(ast, new_cache)) ->
      process_type_ast(
        module_path: module_path,
        type_name: type_name,
        ast: ast,
        new_cache: new_cache,
        rest_queue: rest_queue,
        visited: visited,
        discovered: discovered,
        module_files: module_files,
        errors: errors,
        continue_without_errors: fn(c) { continue_without_errors(c) },
        continue_with_error: fn(c, e) { continue_with_error(c, e) },
      )
  }
}

fn process_type_ast(
  module_path module_path: String,
  type_name type_name: String,
  ast ast: glance.Module,
  new_cache new_cache: Dict(String, glance.Module),
  rest_queue rest_queue: List(#(String, String)),
  visited visited: Set(#(String, String)),
  discovered discovered: List(DiscoveredVariant),
  module_files module_files: Dict(String, String),
  errors errors: List(GenError),
  continue_without_errors continue_without_errors: fn(Dict(String, glance.Module)) ->
    Result(List(DiscoveredVariant), List(GenError)),
  continue_with_error continue_with_error: fn(
    Dict(String, glance.Module),
    GenError,
  ) ->
    Result(List(DiscoveredVariant), List(GenError)),
) -> Result(List(DiscoveredVariant), List(GenError)) {
  // Check type alias — skip silently
  let is_alias =
    list.any(ast.type_aliases, fn(d) { d.definition.name == type_name })
  use <- bool.guard(when: is_alias, return: continue_without_errors(new_cache))
  // Find the custom type definition
  case list.find(ast.custom_types, fn(d) { d.definition.name == type_name }) {
    Error(Nil) ->
      continue_with_error(new_cache, TypeNotFound(module_path:, type_name:))
    Ok(ct_def) -> {
      let custom_type = ct_def.definition
      let resolver = build_type_resolver(ast.imports)
      // Collect variants and field type refs
      let #(new_discovered, new_queue_items) =
        list.fold(custom_type.variants, #(discovered, []), fn(acc, variant) {
          let #(disc_acc, queue_acc) = acc
          let new_disc =
            list.append(disc_acc, [
              DiscoveredVariant(
                module_path: module_path,
                variant_name: variant.name,
                atom_name: to_snake_case(variant.name),
              ),
            ])
          let field_refs =
            collect_variant_field_refs(
              variant: variant,
              resolver: resolver,
              current_module: module_path,
              visited: visited,
            )
          #(new_disc, list.append(queue_acc, field_refs))
        })
      do_walk(
        queue: list.append(rest_queue, new_queue_items),
        visited: visited,
        discovered: new_discovered,
        module_files: module_files,
        parsed_cache: new_cache,
        errors: errors,
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
        |> result.map_error(fn(cause) { CannotReadFile(path: file_path, cause:) }),
      )
      use ast <- result.map(
        glance.module(source)
        |> result.map_error(fn(cause) {
          ParseFailed(path: file_path, cause:)
        }),
      )
      #(ast, dict.insert(parsed_cache, module_path, ast))
    }
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
/// and not in the resolver — meaning it's defined in the current module.
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
/// file being walked — used to resolve unqualified names that are defined
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
      let module_path = resolve_type_module(
        name: name,
        module: module,
        resolver: resolver,
        current_module: current_module,
      )
      case module_path {
        Error(Nil) -> param_refs
        Ok(mp) -> {
          use <- bool.guard(
            when: is_skipped_module(mp),
            return: param_refs,
          )
          list.append([#(mp, name)], param_refs)
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

/// Convert a PascalCase variant name to snake_case for the wire atom.
/// "AdminData" → "admin_data", "One" → "one", "TwoOrMore" → "two_or_more".
fn to_snake_case(name: String) -> String {
  let graphemes = string.to_graphemes(name)
  list.index_fold(graphemes, "", fn(acc, g, i) {
    case i == 0, is_upper_grapheme(g) {
      True, _ -> acc <> string.lowercase(g)
      False, True -> acc <> "_" <> string.lowercase(g)
      False, False -> acc <> g
    }
  })
}

fn is_upper_grapheme(g: String) -> Bool {
  g != string.lowercase(g)
}

fn write_register(
  config config: Config,
  rpcs rpcs: List(Rpc),
) -> Result(Nil, List(GenError)) {
  let client_toml = config.client_root <> "/gleam.toml"
  use toml_source <- result.try(
    simplifile.read(client_toml)
    |> result.map_error(fn(cause) {
      [CannotReadFile(path: client_toml, cause: cause)]
    }),
  )
  let path_deps = parse_path_deps(toml_source: toml_source)
  // Resolve each dep path relative to the generator's CWD (the server
  // package root). A path dep of "../shared" in the client's gleam.toml
  // is relative to the client package, not the server, so prepend
  // client_root and normalize.
  let resolved_deps =
    list.map(path_deps, fn(dep) {
      PathDep(name: dep.name, path: normalize_path_dep(config:, dep:))
    })
  use discovered <- result.try(walk_registry_types(
    rpcs: rpcs,
    path_deps: resolved_deps,
  ))
  io.println(
    "  register: "
    <> int.to_string(list.length(discovered))
    <> " variants discovered from @rpc type graph",
  )
  use _ <- result.try(
    write_register_gleam(config:) |> result.map_error(fn(e) { [e] }),
  )
  write_register_ffi(config:, discovered:) |> result.map_error(fn(e) { [e] })
}

/// Extract `name = { path = "..." }` entries from a gleam.toml source
/// string. Intentionally line-based and forgiving: libero does not need
/// a full TOML parser, only the set of path deps. Lines in `[dev-…]`
/// sections are included (their types would still compile into the
/// client bundle at dev-build time).
fn parse_path_deps(toml_source toml_source: String) -> List(PathDep) {
  string.split(toml_source, "\n")
  |> list.filter_map(parse_path_dep_line)
}

fn parse_path_dep_line(line: String) -> Result(PathDep, Nil) {
  // Examples:
  //   shared = { path = "../shared" }
  //   parrot = { path = "../lib/parrot" }
  // Leading whitespace and optional version pins are not supported;
  // path deps use the object form exclusively.
  let trimmed = string.trim(line)
  use #(name_part, rest1) <- result.try(split_once(string: trimmed, on: "="))
  let name = string.trim(name_part)
  case string.contains(rest1, "path") && string.contains(rest1, "{") {
    False -> Error(Nil)
    True -> {
      use #(_, after_path) <- result.try(split_once(string: rest1, on: "path"))
      use #(_, after_eq) <- result.try(split_once(string: after_path, on: "="))
      let after_eq_trim = string.trim(after_eq)
      use #(_, after_open) <- result.try(split_once(
        string: after_eq_trim,
        on: "\"",
      ))
      use #(path_value, _) <- result.try(split_once(
        string: after_open,
        on: "\"",
      ))
      case name {
        "" -> Error(Nil)
        _ -> Ok(PathDep(name:, path: path_value))
      }
    }
  }
}

fn split_once(
  string string: String,
  on separator: String,
) -> Result(#(String, String), Nil) {
  case string.split_once(string, on: separator) {
    Ok(pair) -> Ok(pair)
    Error(Nil) -> Error(Nil)
  }
}

/// Resolve a path dep path (from the client's gleam.toml) to a path
/// relative to the generator's current working directory (which is
/// the server package root).
fn normalize_path_dep(config config: Config, dep dep: PathDep) -> String {
  // The dep path is written relative to the client package root,
  // but libero runs from the server package. So we prepend the
  // client_root and then let the OS/simplifile walk the resulting
  // path as-is. No canonicalization — simplifile tolerates `..` in
  // paths on POSIX.
  config.client_root <> "/" <> dep.path
}

/// Write the tiny Gleam wrapper that consumers call from main().
fn write_register_gleam(config config: Config) -> Result(Nil, GenError) {
  let content =
    "//// Code generated by libero. DO NOT EDIT.
////
//// Registers every consumer custom type that might cross the wire
//// for this namespace's @rpc calls, so libero's client-side rebuild
//// function can reconstruct tagged JSON objects into Gleam class
//// instances. Call register_all() exactly once at client boot,
//// before the first RPC call fires.

pub fn register_all() -> Nil {
  do_register_all()
}

@external(javascript, \"./rpc_register_ffi.mjs\", \"registerAll\")
fn do_register_all() -> Nil
"
  let output = config.register_gleam_output
  ensure_parent_dir(path: output)
  case simplifile.write(output, content) {
    Ok(_) -> {
      io.println("  wrote " <> output)
      Ok(Nil)
    }
    Error(cause) -> Error(CannotWriteFile(path: output, cause: cause))
  }
}

/// Write the FFI .mjs file with explicit imports and registerConstructor
/// calls for every variant discovered by the type graph walker.
fn write_register_ffi(
  config config: Config,
  discovered discovered: List(DiscoveredVariant),
) -> Result(Nil, GenError) {
  let prefix = config.register_relpath_prefix
  // Collect distinct modules in discovery order (first occurrence wins).
  let distinct_modules =
    list.fold(discovered, #([], set.new()), fn(acc, v) {
      let #(modules_acc, seen) = acc
      case set.contains(seen, v.module_path) {
        True -> acc
        False -> #(
          list.append(modules_acc, [v.module_path]),
          set.insert(seen, v.module_path),
        )
      }
    })
    |> fn(pair) { pair.0 }
  // Assign JS aliases _m0, _m1, … per module
  let module_aliases: Dict(String, String) =
    list.index_fold(distinct_modules, dict.new(), fn(acc, module_path, i) {
      dict.insert(acc, module_path, "_m" <> int.to_string(i))
    })
  let libero_import =
    "import { registerConstructor } from \""
    <> prefix
    <> "libero/libero/rpc_ffi.mjs\";"
  let module_imports =
    list.map(distinct_modules, fn(module_path) {
      let alias = dict.get(module_aliases, module_path) |> result.unwrap("_m0")
      "import * as "
      <> alias
      <> " from \""
      <> prefix
      <> module_to_mjs_path(module_path)
      <> "\";"
    })
  let register_calls =
    list.map(discovered, fn(v) {
      let alias =
        dict.get(module_aliases, v.module_path) |> result.unwrap("_m0")
      "  if ("
      <> alias
      <> "."
      <> v.variant_name
      <> ") registerConstructor(\""
      <> v.atom_name
      <> "\", "
      <> alias
      <> "."
      <> v.variant_name
      <> ");"
    })
  let content =
    "// Code generated by libero. DO NOT EDIT.
//
// Registers every custom type that transitively crosses the wire for
// this namespace's @rpc functions. Walked from @rpc signatures at
// generation time — the consumer does not list types manually.

"
    <> libero_import
    <> "\n"
    <> string.join(module_imports, "\n")
    <> "\n\nexport function registerAll() {\n"
    <> string.join(register_calls, "\n")
    <> "\n}\n"
  let output = config.register_ffi_output
  ensure_parent_dir(path: output)
  case simplifile.write(output, content) {
    Ok(_) -> {
      io.println("  wrote " <> output)
      Ok(Nil)
    }
    Error(cause) -> Error(CannotWriteFile(path: output, cause: cause))
  }
}

/// Convert a Gleam module path like "shared/discount" to its compiled
/// .mjs bundle path "shared/shared/discount.mjs". The first segment
/// is the package name (Gleam convention) and is repeated because
/// the bundle layout is `<package>/<module_path>.mjs`.
fn module_to_mjs_path(module_path: String) -> String {
  case string.split_once(module_path, "/") {
    // Single-segment module path: the whole thing IS the package name
    // and its root module, e.g. "shared" → "shared/shared.mjs".
    Error(Nil) -> module_path <> "/" <> module_path <> ".mjs"
    // Multi-segment: first segment is package, the whole path is
    // repeated under it, e.g. "shared/discount" → "shared/shared/discount.mjs".
    Ok(#(package, _)) -> package <> "/" <> module_path <> ".mjs"
  }
}

// ---------- Source discovery ----------

fn discover_source_files(
  config config: Config,
) -> Result(List(String), GenError) {
  walk_directory(path: config.scan_root)
}

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
  Ok(list.append(acc, nested))
}

fn visit_file(
  acc acc: List(String),
  entry entry: String,
  child child: String,
) -> List(String) {
  let keep =
    string.ends_with(entry, ".gleam") && !list.contains(scan_excludes, entry)
  case keep {
    True -> list.append(acc, [child])
    False -> acc
  }
}

// ---------- @inject scanning (pass 1) ----------

/// Scan every source file for /// @inject functions. Returns the full
/// injection map keyed by function name, plus the inferred session
/// type info (or a sentinel empty SessionInfo if no @inject fns exist).
fn build_inject_map(
  source_files source_files: List(String),
  config config: Config,
) -> Result(#(InjectMap, SessionInfo), List(GenError)) {
  let #(entries, errors) =
    list.fold(source_files, #([], []), fn(acc, path) {
      let #(so_far, errs) = acc
      case extract_injects_from_file(path: path, config: config) {
        Ok(entries) -> #(list.append(so_far, entries), errs)
        Error(e) -> #(so_far, list.append(errs, e))
      }
    })

  case errors {
    [_, ..] -> Error(errors)
    [] -> {
      // All good. Build the map and pick a session type.
      let map =
        list.fold(entries, dict.new(), fn(acc, entry) {
          let #(fn_name, inject_fn, _session) = entry
          dict.insert(acc, fn_name, inject_fn)
        })
      let session = case entries {
        [] -> SessionInfo(type_rendered: "Nil", imports: empty_imports())
        [#(_, _, s), ..] -> s
      }
      Ok(#(map, session))
    }
  }
}

fn extract_injects_from_file(
  path path: String,
  config config: Config,
) -> Result(List(#(String, InjectFn, SessionInfo)), List(GenError)) {
  use source <- result.try(
    simplifile.read(path)
    |> result.map_error(fn(cause) { [CannotReadFile(path: path, cause: cause)] }),
  )
  use module_ast <- result.try(
    glance.module(source)
    |> result.map_error(fn(cause) { [ParseFailed(path: path, cause: cause)] }),
  )

  let annotated =
    find_annotated_functions(source: source, marker: "/// @inject")
  case set.is_empty(annotated) {
    True -> Ok([])
    False ->
      extract_injects_body(
        path: path,
        module_ast: module_ast,
        annotated: annotated,
        config: config,
      )
  }
}

fn extract_injects_body(
  path path: String,
  module_ast module_ast: glance.Module,
  annotated annotated: Set(String),
  config config: Config,
) -> Result(List(#(String, InjectFn, SessionInfo)), List(GenError)) {
  let type_resolver = build_type_resolver(module_ast.imports)
  let module_segments =
    path_to_module_segments(path: path, scan_root: config.scan_root)
  case list.last(module_segments) |> option.from_result {
    None -> Error([EmptyModulePath(path)])
    Some(module_alias) -> {
      let module_path = server_path_to_module(path: path)
      let entries =
        module_ast.functions
        |> list.filter_map(fn(def) {
          let func = def.definition
          case
            func.publicity == glance.Public
            && set.contains(annotated, func.name)
          {
            False -> Error(Nil)
            True ->
              build_inject_entry(
                func: func,
                module_path: module_path,
                module_alias: module_alias,
                resolver: type_resolver,
              )
          }
        })
      Ok(entries)
    }
  }
}

fn build_inject_entry(
  func func: glance.Function,
  module_path module_path: String,
  module_alias module_alias: String,
  resolver resolver: TypeResolver,
) -> Result(#(String, InjectFn, SessionInfo), Nil) {
  case func.parameters {
    [first, ..] -> {
      case first {
        glance.FunctionParameter(type_: option.Some(session_t), ..) -> {
          let #(rendered, imports) =
            render_type(t: session_t, resolver: resolver)
          let inject_fn =
            InjectFn(
              name: func.name,
              module_path: module_path,
              module_alias: module_alias,
            )
          let session = SessionInfo(type_rendered: rendered, imports: imports)
          Ok(#(func.name, inject_fn, session))
        }
        _ -> Error(Nil)
      }
    }
    [] -> Error(Nil)
  }
}

// ---------- Extraction ----------

fn extract_rpcs_from_file(
  path path: String,
  inject_map inject_map: InjectMap,
  config config: Config,
) -> Result(List(Rpc), List(GenError)) {
  use source <- result.try(
    simplifile.read(path)
    |> result.map_error(fn(cause) { [CannotReadFile(path: path, cause: cause)] }),
  )
  use module_ast <- result.try(
    glance.module(source)
    |> result.map_error(fn(cause) { [ParseFailed(path: path, cause: cause)] }),
  )

  let annotated_fn_names =
    find_annotated_functions(source: source, marker: "/// @rpc")
  let type_resolver = build_type_resolver(module_ast.imports)
  let module_segments =
    path_to_module_segments(path: path, scan_root: config.scan_root)

  // For each annotated pub fn, try to build an Rpc. Collect successes
  // AND errors so users see every problem in one run.
  let #(rpcs, errors) =
    list.fold(module_ast.functions, #([], []), fn(acc, def) {
      accumulate_rpc(
        acc: acc,
        def: def,
        annotated_fn_names: annotated_fn_names,
        path: path,
        module_segments: module_segments,
        type_resolver: type_resolver,
        inject_map: inject_map,
        config: config,
      )
    })

  case errors {
    [] -> Ok(rpcs)
    _ -> Error(errors)
  }
}

fn accumulate_rpc(
  acc acc: #(List(Rpc), List(GenError)),
  def def: glance.Definition(glance.Function),
  annotated_fn_names annotated_fn_names: Set(String),
  path path: String,
  module_segments module_segments: List(String),
  type_resolver type_resolver: TypeResolver,
  inject_map inject_map: InjectMap,
  config config: Config,
) -> #(List(Rpc), List(GenError)) {
  let #(rpcs_so_far, errors_so_far) = acc
  let func = def.definition
  let is_rpc =
    func.publicity == glance.Public
    && set.contains(annotated_fn_names, func.name)
  case is_rpc {
    False -> acc
    True -> {
      let result =
        build_rpc(
          func: func,
          path: path,
          module_segments: module_segments,
          resolver: type_resolver,
          inject_map: inject_map,
          config: config,
        )
      case result {
        Ok(rpc) -> #(list.append(rpcs_so_far, [rpc]), errors_so_far)
        Error(errs) -> #(rpcs_so_far, list.append(errors_so_far, errs))
      }
    }
  }
}

/// Find every `pub fn NAME` preceded immediately (with optional blank
/// comments/whitespace) by a line containing the given marker. Returns
/// the set of function names.
fn find_annotated_functions(
  source source: String,
  marker marker: String,
) -> Set(String) {
  let lines = string.split(source, "\n")
  walk_lines(
    lines: lines,
    marker: marker,
    pending_marker: False,
    acc: set.new(),
  )
}

fn walk_lines(
  lines lines: List(String),
  marker marker: String,
  pending_marker pending_marker: Bool,
  acc acc: Set(String),
) -> Set(String) {
  case lines {
    [] -> acc
    [line, ..rest] -> {
      let #(next_pending, next_acc) =
        process_line(
          line: line,
          marker: marker,
          pending_marker: pending_marker,
          acc: acc,
        )
      walk_lines(
        lines: rest,
        marker: marker,
        pending_marker: next_pending,
        acc: next_acc,
      )
    }
  }
}

fn process_line(
  line line: String,
  marker marker: String,
  pending_marker pending_marker: Bool,
  acc acc: Set(String),
) -> #(Bool, Set(String)) {
  let trimmed = string.trim_start(line)
  let is_marker = string.starts_with(trimmed, marker)
  let is_doc = string.starts_with(trimmed, "///")
  let is_blank = trimmed == ""
  case string.starts_with(trimmed, "pub fn ") {
    True -> {
      let next_acc = case pending_marker {
        True -> set.insert(acc, parse_pub_fn_name(trimmed))
        False -> acc
      }
      #(False, next_acc)
    }
    False -> {
      let new_pending = pending_marker && { is_doc || is_blank } || is_marker
      #(new_pending, acc)
    }
  }
}

/// From "pub fn save(...", extract "save".
fn parse_pub_fn_name(line: String) -> String {
  let after_pub_fn = string.drop_start(line, 7)
  // Everything before '('
  string.split_once(after_pub_fn, "(")
  |> result.map(fn(pair) { string.trim(pair.0) })
  |> result.unwrap(string.trim(after_pub_fn))
}

// ---------- Path → module name ----------

/// "../../server/src/server/records.gleam" → ["records"]
/// "../../server/src/server/admin/items.gleam" → ["admin", "items"]
fn path_to_module_segments(
  path path: String,
  scan_root scan_root: String,
) -> List(String) {
  let prefix = scan_root <> "/"
  let after = case string.starts_with(path, prefix) {
    True -> string.drop_start(path, string.length(prefix))
    False -> path
  }
  let without_ext = case string.ends_with(after, ".gleam") {
    True -> string.drop_end(after, 6)
    False -> after
  }
  string.split(without_ext, "/")
}

/// Convert a server-package file path (relative to the server package
/// root, e.g. "src/server/admin/items.gleam") to the Gleam module path
/// used in import statements ("server/admin/items"). Strips the leading
/// "src/" and the ".gleam" suffix.
///
/// Precondition: the path must start with "src/" (no leading "./",
/// no absolute paths). Paths that don't match are returned minus
/// the ".gleam" suffix with no error, which may produce garbage.
/// Libero only calls this with paths produced by its own directory
/// walker, which satisfies the precondition.
fn server_path_to_module(path path: String) -> String {
  let without_src = case string.starts_with(path, "src/") {
    True -> string.drop_start(path, 4)
    False -> path
  }
  case string.ends_with(without_src, ".gleam") {
    True -> string.drop_end(without_src, 6)
    False -> without_src
  }
}

/// Convert a cross-package client file path (relative to the server
/// cwd, e.g. "../client/src/client/generated/libero/admin/rpc_config.gleam")
/// to the Gleam module path used in import statements
/// ("client/generated/libero/admin/rpc_config"). Strips everything up
/// to and including the FIRST occurrence of "/src/" and the ".gleam"
/// suffix.
///
/// Precondition: the path must contain exactly one "/src/" segment
/// and end with ".gleam". Pathological shapes like nested
/// "foo/src/bar/src/baz.gleam" would split on the first "/src/" and
/// silently mis-derive the module. Libero only calls this with paths
/// it builds from --client + convention, which satisfies the
/// precondition.
fn client_path_to_module(path path: String) -> String {
  let after_src = case string.split_once(path, "/src/") {
    Ok(#(_prefix, rest)) -> rest
    Error(Nil) -> path
  }
  case string.ends_with(after_src, ".gleam") {
    True -> string.drop_end(after_src, 6)
    False -> after_src
  }
}

// ---------- Type resolver ----------

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
  )
}

fn build_type_resolver(
  imports: List(glance.Definition(glance.Import)),
) -> TypeResolver {
  let empty_unq: Dict(String, String) = dict.new()
  let empty_al: Dict(String, String) = dict.new()
  let init = TypeResolver(unqualified: empty_unq, aliased: empty_al)
  list.fold(imports, init, fn(acc, def) {
    let imp = def.definition
    let module_path = imp.module
    // Unqualified types: `import foo.{type Bar}` → "Bar" -> module_path
    let acc =
      list.fold(imp.unqualified_types, acc, fn(acc, uq) {
        let name = case uq.alias {
          Some(a) -> a
          None -> uq.name
        }
        TypeResolver(
          unqualified: dict.insert(acc.unqualified, name, module_path),
          aliased: acc.aliased,
        )
      })
    // Module alias: `import shared/record` → "record" -> "shared/record"
    let alias_name = case imp.alias {
      Some(glance.Named(name)) -> name
      _ -> default_module_alias(module_path)
    }
    TypeResolver(
      unqualified: acc.unqualified,
      aliased: dict.insert(acc.aliased, alias_name, module_path),
    )
  })
}

fn default_module_alias(module_path: String) -> String {
  string.split(module_path, "/")
  |> list.last
  |> result.unwrap(module_path)
}

// ---------- RPC builder ----------

fn build_rpc(
  func func: glance.Function,
  path path: String,
  module_segments module_segments: List(String),
  resolver resolver: TypeResolver,
  inject_map inject_map: InjectMap,
  config config: Config,
) -> Result(Rpc, List(GenError)) {
  let fn_name = func.name
  use return_type <- result.try(case func.return {
    Some(rt) -> Ok(rt)
    None -> Error([NoReturnType(path, fn_name)])
  })
  use server_module_alias <- result.try(
    list.last(module_segments)
    |> result.replace_error([EmptyModulePath(path)]),
  )

  // Classify each parameter as Injected (label matches an @inject
  // function) or Wire (carried over the wire). Collect errors for
  // any param missing a label.
  let #(classified, stub_imports, param_errors) =
    list.index_fold(
      func.parameters,
      #([], empty_imports(), []),
      fn(acc, param, i) {
        classify_parameter(
          acc: acc,
          param: param,
          i: i,
          inject_map: inject_map,
          resolver: resolver,
          path: path,
          fn_name: fn_name,
        )
      },
    )

  // Extract wire params for stub rendering (the classification is
  // interleaved but stubs only see the wire ones).
  let wire_params =
    list.filter_map(classified, fn(c) {
      case c {
        Wire(p) -> Ok(p)
        Injected(_, _) -> Error(Nil)
      }
    })

  case param_errors {
    [_, ..] -> Error(param_errors)
    [] ->
      Ok(assemble_rpc(
        fn_name: fn_name,
        path: path,
        module_segments: module_segments,
        server_module_alias: server_module_alias,
        classified: classified,
        wire_params: wire_params,
        stub_imports: stub_imports,
        return_type: return_type,
        resolver: resolver,
        config: config,
      ))
  }
}

fn classify_parameter(
  acc acc: #(List(ClassifiedParam), ImportMap, List(GenError)),
  param param: glance.FunctionParameter,
  i i: Int,
  inject_map inject_map: InjectMap,
  resolver resolver: TypeResolver,
  path path: String,
  fn_name fn_name: String,
) -> #(List(ClassifiedParam), ImportMap, List(GenError)) {
  let #(classified_so_far, imports_so_far, errors_so_far) = acc
  case param {
    glance.FunctionParameter(label: Some(label), name: _, type_: Some(type_)) ->
      classify_labelled_parameter(
        classified_so_far: classified_so_far,
        imports_so_far: imports_so_far,
        errors_so_far: errors_so_far,
        label: label,
        type_: type_,
        inject_map: inject_map,
        resolver: resolver,
      )
    _ -> #(
      classified_so_far,
      imports_so_far,
      list.append(errors_so_far, [UnlabelledParam(path, fn_name, i + 1)]),
    )
  }
}

fn classify_labelled_parameter(
  classified_so_far classified_so_far: List(ClassifiedParam),
  imports_so_far imports_so_far: ImportMap,
  errors_so_far errors_so_far: List(GenError),
  label label: String,
  type_ type_: glance.Type,
  inject_map inject_map: InjectMap,
  resolver resolver: TypeResolver,
) -> #(List(ClassifiedParam), ImportMap, List(GenError)) {
  case dict.get(inject_map, label) |> option.from_result {
    Some(inject_fn) -> #(
      list.append(classified_so_far, [
        Injected(label: label, inject: inject_fn),
      ]),
      imports_so_far,
      errors_so_far,
    )
    None -> {
      let #(rendered, new_imports) = render_type(t: type_, resolver: resolver)
      let merged_imports = merge_imports(a: imports_so_far, b: new_imports)
      #(
        list.append(classified_so_far, [
          Wire(Param(label: label, rendered_type: rendered)),
        ]),
        merged_imports,
        errors_so_far,
      )
    }
  }
}

fn assemble_rpc(
  fn_name fn_name: String,
  path path: String,
  module_segments module_segments: List(String),
  server_module_alias server_module_alias: String,
  classified classified: List(ClassifiedParam),
  wire_params wire_params: List(Param),
  stub_imports stub_imports: ImportMap,
  return_type return_type: glance.Type,
  resolver resolver: TypeResolver,
  config config: Config,
) -> Rpc {
  let #(return_shape, return_imports) =
    render_return(t: return_type, resolver: resolver)
  // Every stub needs the RpcError type. Bare-T stubs also
  // need Never. Wrapped stubs don't (E is a real type).
  let libero_types = case return_shape {
    Bare(_) -> ["Never", "RpcError"]
    Wrapped(_, _) -> ["RpcError"]
  }
  let libero_import =
    list.fold(libero_types, dict.new(), fn(acc, t) {
      merge_imports(
        a: acc,
        b: single_import(module_path: "libero/error", type_name: t),
      )
    })
  let merged_stub_imports =
    stub_imports
    |> merge_imports(b: return_imports)
    |> merge_imports(b: libero_import)
  let wire_name = case config.namespace {
    Some(ns) ->
      string.join(list.append([ns, ..module_segments], [fn_name]), ".")
    None -> string.join(list.append(module_segments, [fn_name]), ".")
  }
  let server_module = server_path_to_module(path: path)
  let client_stub_path =
    config.stub_root <> "/" <> string.join(module_segments, "/") <> ".gleam"
  Rpc(
    wire_name: wire_name,
    fn_name: fn_name,
    server_module: server_module,
    server_module_alias: server_module_alias,
    client_stub_path: client_stub_path,
    all_params: classified,
    wire_params: wire_params,
    return_shape: return_shape,
    stub_imports: merged_stub_imports,
  )
}

// ---------- Import grouping helpers ----------
//
// Imports are `Dict(module_path, Set(type_names))`. Merging =
// per-key set union. Rendering = `import foo.{type A, type B}`.

type ImportMap =
  Dict(String, Set(String))

fn empty_imports() -> ImportMap {
  dict.new()
}

fn merge_imports(a a: ImportMap, b b: ImportMap) -> ImportMap {
  dict.fold(b, a, fn(acc, module_path, types) {
    let existing =
      dict.get(acc, module_path)
      |> result.unwrap(set.new())
    dict.insert(acc, module_path, set.union(existing, types))
  })
}

fn single_import(
  module_path module_path: String,
  type_name type_name: String,
) -> ImportMap {
  dict.insert(dict.new(), module_path, set.insert(set.new(), type_name))
}

fn empty_module_import(module_path: String) -> ImportMap {
  dict.insert(dict.new(), module_path, set.new())
}

fn render_imports(imports: ImportMap) -> List(String) {
  imports
  |> dict.to_list
  |> list.sort(fn(a, b) {
    let #(path_a, _) = a
    let #(path_b, _) = b
    string.compare(path_a, path_b)
  })
  |> list.map(fn(entry) {
    let #(module_path, types) = entry
    let type_list = set.to_list(types) |> list.sort(string.compare)
    case type_list {
      [] -> "import " <> module_path
      _ -> {
        let type_clause =
          type_list
          |> list.map(fn(t) { "type " <> t })
          |> string.join(", ")
        "import " <> module_path <> ".{" <> type_clause <> "}"
      }
    }
  })
}

// ---------- Return shape detection ----------

/// Detect whether a server fn's return type is `Result(T, E)` (Wrapped)
/// or a bare `T` (Bare). Render both halves and collect their imports.
fn render_return(
  t t: glance.Type,
  resolver resolver: TypeResolver,
) -> #(ReturnShape, ImportMap) {
  case t {
    glance.NamedType(
      name: "Result",
      module: None,
      parameters: [ok_t, err_t],
      ..,
    ) -> {
      let #(ok_rendered, ok_imports) = render_type(t: ok_t, resolver: resolver)
      let #(err_rendered, err_imports) =
        render_type(t: err_t, resolver: resolver)
      #(
        Wrapped(ok_rendered: ok_rendered, err_rendered: err_rendered),
        merge_imports(a: ok_imports, b: err_imports),
      )
    }
    _ -> {
      let #(rendered, imports) = render_type(t: t, resolver: resolver)
      #(Bare(ok_rendered: rendered), imports)
    }
  }
}

// ---------- Type rendering ----------

fn render_type(
  t t: glance.Type,
  resolver resolver: TypeResolver,
) -> #(String, ImportMap) {
  let empty = empty_imports()
  case t {
    glance.NamedType(name:, module:, parameters:, ..) -> {
      let #(param_strs, param_imports) =
        list.fold(parameters, #([], empty), fn(acc, p) {
          let #(strs, imps) = acc
          let #(s, i) = render_type(t: p, resolver: resolver)
          #(list.append(strs, [s]), merge_imports(a: imps, b: i))
        })
      let base = case module {
        Some(m) -> m <> "." <> name
        None -> name
      }
      let rendered = case param_strs {
        [] -> base
        _ -> base <> "(" <> string.join(param_strs, ", ") <> ")"
      }
      let imports_for_this =
        resolve_import(name: name, module: module, resolver: resolver)
      #(rendered, merge_imports(a: imports_for_this, b: param_imports))
    }
    glance.TupleType(elements:, ..) -> {
      let #(strs, imps) =
        list.fold(elements, #([], empty), fn(acc, p) {
          let #(strs, imps) = acc
          let #(s, i) = render_type(t: p, resolver: resolver)
          #(list.append(strs, [s]), merge_imports(a: imps, b: i))
        })
      #("#(" <> string.join(strs, ", ") <> ")", imps)
    }
    glance.FunctionType(..) -> #("fn(...)", empty)
    glance.VariableType(name:, ..) -> #(name, empty)
    glance.HoleType(..) -> #("_", empty)
  }
}

/// Decide whether a type name needs an import and return an
/// ImportMap entry.
fn resolve_import(
  name name: String,
  module module: option.Option(String),
  resolver resolver: TypeResolver,
) -> ImportMap {
  case is_primitive_or_builtin(name), module {
    True, _ -> empty_imports()
    False, Some(alias) ->
      // Qualified: `record.Record` → look up alias, import module
      // for qualified access (no unqualified types from this ref).
      dict.get(resolver.aliased, alias)
      |> result.map(empty_module_import)
      |> result.unwrap(empty_imports())
    False, None ->
      // Unqualified: `Record` → look up, bring in as unqualified type.
      dict.get(resolver.unqualified, name)
      |> result.map(fn(module_path) {
        single_import(module_path: module_path, type_name: name)
      })
      |> result.unwrap(empty_imports())
  }
}

fn is_primitive_or_builtin(name: String) -> Bool {
  list.contains(
    ["Int", "Float", "String", "Bool", "Nil", "BitArray", "List"],
    name,
  )
}

// ---------- Stub file rendering ----------

fn write_stub_files(
  rpcs rpcs: List(Rpc),
  config config: Config,
) -> Result(Nil, GenError) {
  let grouped = group_by_path(rpcs)
  // Fold over the dict so we can short-circuit on the first write error.
  dict.fold(grouped, Ok(Nil), fn(acc, path, rpcs_in_file) {
    result.try(acc, fn(_) {
      write_stub_file(path: path, rpcs_in_file: rpcs_in_file, config: config)
    })
  })
}

fn write_stub_file(
  path path: String,
  rpcs_in_file rpcs_in_file: List(Rpc),
  config config: Config,
) -> Result(Nil, GenError) {
  let content = render_stub_file(rpcs: rpcs_in_file, config: config)
  ensure_parent_dir(path: path)
  case simplifile.write(path, content) {
    Ok(_) -> {
      io.println("  wrote " <> path)
      Ok(Nil)
    }
    Error(cause) -> Error(CannotWriteFile(path: path, cause: cause))
  }
}

fn extract_dir(path: String) -> String {
  case string.split(path, "/") |> list.reverse {
    [_last, ..rest_rev] -> string.join(list.reverse(rest_rev), "/")
    [] -> "."
  }
}

fn group_by_path(rpcs: List(Rpc)) -> Dict(String, List(Rpc)) {
  let empty: Dict(String, List(Rpc)) = dict.new()
  list.fold(rpcs, empty, fn(acc, rpc) {
    let existing =
      dict.get(acc, rpc.client_stub_path)
      |> result.unwrap([])
    dict.insert(acc, rpc.client_stub_path, list.append(existing, [rpc]))
  })
}

fn render_stub_file(
  rpcs rpcs: List(Rpc),
  config config: Config,
) -> String {
  let all_imports =
    rpcs
    |> list.fold(empty_imports(), fn(acc, rpc) {
      merge_imports(a: acc, b: rpc.stub_imports)
    })
    |> render_imports

  let rpc_config_module = client_path_to_module(path: config.config_output)
  let standard_imports =
    "import "
    <> rpc_config_module
    <> "\n"
    <> "import libero/rpc\n"
    <> "import lustre/effect.{type Effect}"

  let extra_imports = case all_imports {
    [] -> ""
    _ -> "\n" <> string.join(all_imports, "\n")
  }

  let stubs =
    rpcs
    |> list.map(render_stub_fn)
    |> string.join("\n\n")

  "//// Code generated by libero. DO NOT EDIT.
////
//// Regenerated from the /// @rpc-annotated server functions whenever
//// those source files change. Edit the server function signature (add
//// or remove labels, rename parameters) and re-run bin/dev.

" <> standard_imports <> extra_imports <> "\n\n" <> stubs <> "\n"
}

fn render_stub_fn(rpc: Rpc) -> String {
  let labelled_params =
    rpc.wire_params
    |> list.map(fn(p) {
      "  " <> p.label <> " " <> p.label <> ": " <> p.rendered_type <> ","
    })
    |> string.join("\n")

  // When there are zero wire params the labelled block is empty,
  // emit nothing so we don't get a blank line before on_response.
  // Otherwise append a newline so on_response starts on its own line.
  let labelled_params_block = case labelled_params {
    "" -> ""
    _ -> labelled_params <> "\n"
  }

  let args_tuple = render_args_tuple(rpc.wire_params)

  // Every stub uses call_by_name now. The unit variant is gone
  // because Nil returns are handled by the uniform Result envelope
  // (Ok(Nil) on the wire).
  let response_type = case rpc.return_shape {
    Bare(ok) -> "Result(" <> ok <> ", RpcError(Never))"
    Wrapped(ok, err) -> "Result(" <> ok <> ", RpcError(" <> err <> "))"
  }

  "pub fn "
  <> rpc.fn_name
  <> "(\n"
  <> labelled_params_block
  <> "  on_response on_response: fn("
  <> response_type
  <> ") -> msg,\n) -> Effect(msg) {\n"
  <> "  rpc.call_by_name(\n    url: rpc_config.ws_url,\n    name: \""
  <> rpc.wire_name
  <> "\",\n    args: "
  <> args_tuple
  <> ",\n    wrap: on_response,\n  )\n}"
}

fn render_args_tuple(params: List(Param)) -> String {
  case params {
    [] -> "Nil"
    [only] -> only.label
    _ -> {
      let names = list.map(params, fn(p) { p.label })
      "#(" <> string.join(names, ", ") <> ")"
    }
  }
}

// ---------- Dispatch file rendering ----------

/// Create the parent directory for the given file path, ignoring any
/// error. create_directory_all is idempotent (no error if the dir
/// already exists) and any real write failure surfaces on the
/// subsequent simplifile.write call.
fn ensure_parent_dir(path path: String) -> Nil {
  let _discard = simplifile.create_directory_all(extract_dir(path))
  Nil
}

fn write_dispatch(
  rpcs rpcs: List(Rpc),
  inject_map inject_map: InjectMap,
  session session: SessionInfo,
  config config: Config,
) -> Result(Nil, GenError) {
  let content =
    render_dispatch(
      rpcs: rpcs,
      inject_map: inject_map,
      session: session,
      config: config,
    )
  let dispatch_output = config.dispatch_output
  ensure_parent_dir(path: dispatch_output)
  case simplifile.write(dispatch_output, content) {
    Ok(_) -> {
      io.println("  wrote " <> dispatch_output)
      Ok(Nil)
    }
    Error(cause) -> Error(CannotWriteFile(path: dispatch_output, cause: cause))
  }
}

fn render_dispatch(
  rpcs rpcs: List(Rpc),
  inject_map inject_map: InjectMap,
  session session: SessionInfo,
  config config: Config,
) -> String {
  let handle_name = case config.namespace {
    Some(ns) -> "handle_" <> ns
    None -> "handle"
  }

  // If every RPC returns a bare T (no Result), the generated code
  // never references AppError, so leave it out of the import to avoid
  // an unused-constructor warning.
  let has_wrapped =
    list.any(rpcs, fn(rpc) {
      case rpc.return_shape {
        Wrapped(_, _) -> True
        Bare(_) -> False
      }
    })
  let error_import = case has_wrapped {
    True ->
      "import libero/error.{
  type PanicInfo, AppError, InternalError, MalformedRequest, PanicInfo,
  UnknownFunction,
}"
    False ->
      "import libero/error.{
  type PanicInfo, InternalError, MalformedRequest, PanicInfo, UnknownFunction,
}"
  }

  // If there are no @inject fns, the inner dispatch function never
  // reads its session arg. Drop it from the inner signature and
  // underscore-prefix the outer handle's binding name so neither
  // triggers an unused-parameter warning. The public `session:` label
  // stays the same so consumers always call `handle(session: _, text: _)`.
  let session_is_used = !dict.is_empty(inject_map)
  let outer_session_binding = case session_is_used {
    True -> "session"
    False -> "_session"
  }
  let dispatch_session_param = case session_is_used {
    True -> "  session session: " <> session.type_rendered <> ",\n"
    False -> ""
  }
  let dispatch_call_session = case session_is_used {
    True -> "session: session, "
    False -> ""
  }
  // Imports for server modules we dispatch into.
  let server_imports =
    rpcs
    |> list.map(fn(rpc) { rpc.server_module })
    |> list.unique
    |> list.sort(string.compare)
    |> list.map(fn(m) { "import " <> m })
    |> string.join("\n")

  // Imports for inject modules (the generated dispatch calls
  // e.g. `rpc_inject.conn(session)` so needs to import server/rpc_inject).
  let inject_imports =
    dict.values(inject_map)
    |> list.map(fn(f) { f.module_path })
    |> list.unique
    |> list.sort(string.compare)
    |> list.map(fn(m) { "import " <> m })
    |> string.join("\n")

  // Imports for the session type itself.
  let session_imports =
    render_imports(session.imports)
    |> string.join("\n")

  let cases =
    rpcs
    |> list.map(render_dispatch_case)
    |> string.join("\n\n")

  let combined_imports =
    [server_imports, inject_imports, session_imports]
    |> list.filter(fn(s) { s != "" })
    |> string.join("\n")

  "//// Code generated by libero. DO NOT EDIT.
////
//// Regenerated from the /// @rpc-annotated server functions whenever
//// those source files change.

import gleam/dynamic.{type Dynamic}
import gleam/option.{type Option, None, Some}
" <> error_import <> "
import libero/trace
import libero/wire
" <> combined_imports <> "

/// Handle an incoming RPC call envelope. Returns a tuple of:
///   - the JSON-encoded response string (to send back to the client)
///   - `Option(PanicInfo)`: `Some` if a server function panicked,
///     letting the caller log, report, or escalate however they
///     prefer. Libero has no logging dependency of its own.
///
/// Malformed requests, unknown functions, and panics all flow back
/// as typed error envelopes. The WebSocket connection is never
/// dropped on bad input.
pub fn " <> handle_name <> "(
  session " <> outer_session_binding <> ": " <> session.type_rendered <> ",
  text text: String,
) -> #(String, Option(PanicInfo)) {
  case wire.decode_call(text) {
    Ok(#(name, args)) -> dispatch(" <> dispatch_call_session <> "name: name, args: args)
    Error(wire.DecodeError(message: _msg, cause: _cause)) ->
      // The typed error is bound by field so neither the message nor
      // the underlying json.DecodeError is silently discarded; the
      // client only needs to know the envelope was malformed.
      #(wire.encode(Error(MalformedRequest)), None)
  }
}

fn dispatch(
" <> dispatch_session_param <> "  name name: String,
  args args: List(Dynamic),
) -> #(String, Option(PanicInfo)) {
  case name, args {
" <> cases <> "

    _, _ -> #(wire.encode(Error(UnknownFunction(name: name))), None)
  }
}

@external(erlang, \"gleam_stdlib\", \"identity\")
fn coerce(value: Dynamic) -> a
"
}

fn render_dispatch_case(rpc: Rpc) -> String {
  let arity = list.length(rpc.wire_params)
  let pattern = render_pattern(arity)
  let call = render_dispatch_call(rpc)

  // Common panic-handling tail: when try_call returns Error(reason),
  // generate a trace_id, build a PanicInfo for the caller to consume,
  // and encode the trace_id into the wire response.
  let panic_arm =
    "        Error(reason) -> {\n"
    <> "          let trace_id = trace.new_trace_id()\n"
    <> "          #(\n"
    <> "            wire.encode(Error(InternalError(trace_id: trace_id))),\n"
    <> "            Some(PanicInfo(\n"
    <> "              trace_id: trace_id,\n"
    <> "              fn_name: \""
    <> rpc.wire_name
    <> "\",\n"
    <> "              reason: reason,\n"
    <> "            )),\n"
    <> "          )\n"
    <> "        }\n"

  let try_prefix =
    "case trace.try_call(fn() {\n        " <> call <> "\n      }) {\n"

  let body = case rpc.return_shape {
    Bare(_) ->
      try_prefix
      <> "        Ok(value) -> #(wire.encode(Ok(value)), None)\n"
      <> panic_arm
      <> "      }"
    Wrapped(_, _) ->
      try_prefix
      <> "        Ok(Ok(value)) -> #(wire.encode(Ok(value)), None)\n"
      <> "        Ok(Error(app_err)) -> #(wire.encode(Error(AppError(app_err))), None)\n"
      <> panic_arm
      <> "      }"
  }

  "    \"" <> rpc.wire_name <> "\", " <> pattern <> " ->\n      " <> body
}

fn render_pattern(arity: Int) -> String {
  case arity {
    0 -> "[]"
    _ -> {
      let names = indexes(arity) |> list.map(fn(i) { "a" <> int.to_string(i) })
      "[" <> string.join(names, ", ") <> "]"
    }
  }
}

fn render_dispatch_call(rpc: Rpc) -> String {
  // Walk all_params in order and emit either the inject call or the
  // coerce(aN) expression. Wire params are numbered 1..N based on
  // their position in the wire_params list (not all_params).
  let #(labelled_args, _wire_index) =
    list.fold(rpc.all_params, #([], 1), fn(acc, cp) {
      let #(args_so_far, wire_idx) = acc
      case cp {
        Injected(label:, inject:) -> {
          let arg =
            label
            <> ": "
            <> inject.module_alias
            <> "."
            <> inject.name
            <> "(session)"
          #(list.append(args_so_far, [arg]), wire_idx)
        }
        Wire(param:) -> {
          let arg =
            param.label <> ": coerce(a" <> int.to_string(wire_idx) <> ")"
          #(list.append(args_so_far, [arg]), wire_idx + 1)
        }
      }
    })
  rpc.server_module_alias
  <> "."
  <> rpc.fn_name
  <> "("
  <> string.join(labelled_args, ", ")
  <> ")"
}

fn indexes(n: Int) -> List(Int) {
  build_indexes(n: n, acc: [])
}

fn build_indexes(n n: Int, acc acc: List(Int)) -> List(Int) {
  case n {
    0 -> acc
    _ -> build_indexes(n: n - 1, acc: [n, ..acc])
  }
}
