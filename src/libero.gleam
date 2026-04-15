//// v3 message-type code generator.
////
//// Scans `shared/src/shared/**/*.gleam` for modules that export
//// `ToServer` or `ToClient` custom types and produces:
////
////   1. `server/src/server/generated/libero/dispatch.gleam`, a routing
////      function that decodes incoming wire calls and dispatches them to
////      the appropriate handler module.
////
////   2. Per-module `client/src/client/generated/libero/<module>.gleam`
////      files with `send` functions that wrap `rpc.send`.
////
////   3. `client/src/client/generated/libero/rpc_config.gleam`, the
////      WebSocket URL configuration for the client.
////
////   4. `client/src/client/generated/libero/rpc_register.gleam` and
////      `rpc_register_ffi.mjs`, which register every custom type that
////      may appear on the wire so the client can reconstruct ETF terms.
////
////   5. A `.erl` file that pre-registers all constructor atoms so
////      `binary_to_term([safe])` can decode client ETF payloads.
////
//// ## Conventions
////
//// - Message modules live in the shared package and export a `ToServer`
////   type (messages the client sends to the server) and/or a `ToClient`
////   type (messages the server pushes to the client).
////
//// - Each message module with `ToServer` must have a corresponding
////   handler at `server/src/server/handlers/<module_name>.gleam` that
////   exports a `handle` function.
////
//// - The server package must export `SharedState` from
////   `server/src/server/shared_state.gleam` and `AppError` from
////   `server/src/server/app_error.gleam`.

import argv
import glance
import gleam/bool
import gleam/dict.{type Dict}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import simplifile

// ---------- Types ----------

/// A message module discovered in the shared package.
pub type MessageModule {
  MessageModule(
    /// Module path relative to shared/src/, e.g. "shared/todos"
    module_path: String,
    /// Absolute file path
    file_path: String,
    /// Whether this module exports a ToServer type
    has_to_server: Bool,
    /// Whether this module exports a ToClient type
    has_to_client: Bool,
  )
}

// ---------- Errors ----------

pub type GenError {
  CannotReadDir(path: String, cause: simplifile.FileError)
  CannotReadFile(path: String, cause: simplifile.FileError)
  CannotWriteFile(path: String, cause: simplifile.FileError)
  ParseFailed(path: String, cause: glance.Error)
  EmptyModulePath(path: String)
  UnresolvedTypeModule(module_path: String, type_name: String)
  TypeNotFound(module_path: String, type_name: String)
  MissingSharedState(expected_path: String)
  MissingAppError(expected_path: String)
  MissingHandler(message_module: String, expected_path: String)
  NoMessageModules(shared_path: String)
}

// ---------- CLI configuration ----------

/// How the generated client resolves its WebSocket URL.
type WsMode {
  /// Hardcoded full URL (from --ws-url). Single-host deployments.
  WsFullUrl(url: String)
  /// Path-only, resolved at runtime from window.location (from --ws-path).
  /// Multi-tenant deployments where multiple subdomains share one bundle.
  WsPathOnly(path: String)
}

/// Everything libero needs from its invocation args, normalized.
/// Paths are derived from --namespace and --client with single-SPA
/// defaults when those flags are absent.
type Config {
  Config(
    ws_mode: WsMode,
    namespace: option.Option(String),
    client_root: String,
    /// Path to the generated .erl file that pre-registers all
    /// constructor atoms for safe ETF decoding.
    atoms_output: String,
    /// Erlang module name for the atoms .erl file, using Gleam's
    /// path-to-module convention (@ separators).
    atoms_module: String,
    config_output: String,
    register_gleam_output: String,
    register_ffi_output: String,
    /// Bundle-relative prefix that prepends every import in the
    /// generated FFI .mjs file. Depth depends on where the register
    /// files land inside the consumer client package.
    register_relpath_prefix: String,
    /// v3: Path to the shared package src directory (e.g. "../shared/src/shared").
    /// Used by scan_message_modules and walk_message_registry_types.
    shared_src: option.Option(String),
    /// v3: Path to the server package src directory (e.g. "src").
    /// Used by validate_conventions and deriving server_generated.
    server_src: option.Option(String),
    /// v3: Where to write server-side generated dispatch (e.g. "src/server/generated/libero").
    v3_server_generated: String,
    /// v3: Where to write client-side generated send functions (e.g. "../client/src/client/generated/libero").
    v3_client_generated: String,
  )
}

fn parse_config() -> Config {
  let args = argv.load().arguments
  let ws_mode = case
    find_flag(args: args, name: "--ws-url"),
    find_flag(args: args, name: "--ws-path")
  {
    Ok(url), Error(Nil) -> WsFullUrl(url: url)
    Error(Nil), Ok(path) -> WsPathOnly(path: path)
    Ok(_), Ok(_) -> {
      io.println_error("error: --ws-url and --ws-path are mutually exclusive")
      io.println_error(
        "  Use --ws-url for single-host deployments (hardcoded URL),",
      )
      io.println_error(
        "  or --ws-path for multi-tenant deployments (resolved at runtime).",
      )
      let _halt = halt(1)
      WsFullUrl(url: "")
    }
    Error(Nil), Error(Nil) -> {
      io.println_error("error: --ws-url or --ws-path is required")
      io.println_error("")
      io.println_error(
        "  --ws-url=<url>   Hardcoded WebSocket URL for single-host deployments.",
      )
      io.println_error(
        "  --ws-path=<path>  Path-only, resolved at runtime from the browser's",
      )
      io.println_error(
        "                    location. Use for multi-tenant subdomain deployments.",
      )
      io.println_error("")
      io.println_error("  Examples:")
      io.println_error(
        "    gleam run -m libero -- --ws-url=wss://example.com/ws/rpc",
      )
      io.println_error(
        "    gleam run -m libero -- --ws-path=/ws/admin --namespace=admin",
      )
      let _halt = halt(1)
      WsFullUrl(url: "")
    }
  }
  let namespace = case find_flag(args: args, name: "--namespace") {
    Ok(ns) -> Some(ns)
    Error(Nil) -> None
  }
  let client_root = case find_flag(args: args, name: "--client") {
    Ok(path) -> path
    Error(Nil) -> "../client"
  }
  // v3 flags: --shared= and --server= enable v3 message-module mode.
  let shared_root = find_flag(args: args, name: "--shared")
  let server_root = find_flag(args: args, name: "--server")
  build_config(
    ws_mode: ws_mode,
    namespace: namespace,
    client_root: client_root,
    shared_root: shared_root,
    server_root: server_root,
  )
}

/// Derive all paths from --namespace and --client. When namespace is
/// None the paths land under generated/libero/ inside the consumer's
/// server and client packages. When set, paths are nested one level
/// deeper under generated/libero/<namespace>/ to keep multi-SPA output
/// physically isolated.
fn build_config(
  ws_mode ws_mode: WsMode,
  namespace namespace: option.Option(String),
  client_root client_root: String,
  shared_root shared_root: Result(String, Nil),
  server_root server_root: Result(String, Nil),
) -> Config {
  // In the final JS bundle, registration files land at:
  //   <bundle_root>/<client_pkg>/client/generated/libero/[<ns>/]rpc_register_ffi.mjs
  // So from the ffi file's directory, the bundle root is:
  //   - 4 levels up for no-namespace (client_pkg/client/generated/libero/)
  //   - 5 levels up for namespaced  (client_pkg/client/generated/libero/<ns>/)
  let #(
    atoms_output,
    atoms_module,
    config_output,
    register_gleam_output,
    register_ffi_output,
    register_relpath_prefix,
  ) = case namespace {
    None -> #(
      "src/server@generated@libero@rpc_atoms.erl",
      "server@generated@libero@rpc_atoms",
      client_root <> "/src/client/generated/libero/rpc_config.gleam",
      client_root <> "/src/client/generated/libero/rpc_register.gleam",
      client_root <> "/src/client/generated/libero/rpc_register_ffi.mjs",
      "../../../../",
    )
    Some(ns) -> #(
      "src/server@generated@libero@" <> ns <> "@rpc_atoms.erl",
      "server@generated@libero@" <> ns <> "@rpc_atoms",
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
  // v3 paths: derived from --shared and --server flags.
  // shared_src = <shared_root>/src/shared  (the shared package's module src dir)
  // server_src = <server_root>/src         (the server package's src dir)
  // v3_server_generated and v3_client_generated are where dispatch.gleam and
  // client send stubs are written, matching the convention used by the consumer.
  let shared_src: Option(String) =
    shared_root
    |> result.map(fn(root) { root <> "/src/shared" })
    |> option.from_result
  let server_src: Option(String) =
    server_root
    |> result.map(fn(root) { root <> "/src" })
    |> option.from_result
  let v3_server_generated = case namespace {
    None -> "src/server/generated/libero"
    Some(ns) -> "src/server/generated/libero/" <> ns
  }
  let v3_client_generated = case namespace {
    None -> client_root <> "/src/client/generated/libero"
    Some(ns) -> client_root <> "/src/client/generated/libero/" <> ns
  }
  Config(
    ws_mode: ws_mode,
    namespace: namespace,
    client_root: client_root,
    atoms_output: atoms_output,
    atoms_module: atoms_module,
    config_output: config_output,
    register_gleam_output: register_gleam_output,
    register_ffi_output: register_ffi_output,
    register_relpath_prefix: register_relpath_prefix,
    shared_src: shared_src,
    server_src: server_src,
    v3_server_generated: v3_server_generated,
    v3_client_generated: v3_client_generated,
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
  let Nil = trap_signals()
  let config = parse_config()

  // v3 mode is enabled when --shared is provided. In v3 mode, libero
  // scans shared message modules instead of server function annotations.
  case config.shared_src {
    Some(shared_src) -> {
      io.println("libero: v3 mode — scanning shared message modules at " <> shared_src)
      case run_v3(config: config, shared_src: shared_src) {
        Ok(count) -> {
          io.println(
            "libero: done. processed "
            <> int.to_string(count)
            <> " message module(s)",
          )
          let _halt = halt(0)
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
    None -> {
      io.println_error(
        "error: --shared is required. libero v3 requires --shared=<path to shared package>",
      )
      io.println_error("")
      io.println_error("  Example:")
      io.println_error(
        "    gleam run -m libero -- --ws-path=/ws/admin --shared=../shared --server=.",
      )
      let _halt = halt(1)
    }
  }
}

/// v3 pipeline: scan shared message modules, validate conventions, walk
/// types, and generate dispatch + client send stubs + register + atoms.
fn run_v3(
  config config: Config,
  shared_src shared_src: String,
) -> Result(Int, List(GenError)) {
  use #(message_modules, module_files) <- result.try(
    scan_message_modules(shared_src: shared_src),
  )
  io.println(
    "libero: found "
    <> int.to_string(list.length(message_modules))
    <> " message module(s)",
  )

  let server_src = option.unwrap(config.server_src, "src")
  let validation_errors =
    validate_conventions(message_modules: message_modules, server_src: server_src)
  case validation_errors {
    [_, ..] -> Error(validation_errors)
    [] -> {
      use discovered <- result.try(
        walk_message_registry_types(
          message_modules: message_modules,
          module_files: module_files,
        ),
      )
      io.println(
        "libero: discovered "
        <> int.to_string(list.length(discovered))
        <> " type variant(s) for registration",
      )

      // Generate server dispatch module.
      use _ <- result.try(
        write_v3_dispatch(
          message_modules: message_modules,
          server_generated: config.v3_server_generated,
        )
        |> result.map_error(fn(e) { [e] }),
      )

      // Generate client send stubs.
      use _ <- result.try(
        write_v3_send_functions(
          message_modules: message_modules,
          client_generated: config.v3_client_generated,
        ),
      )

      // Generate WebSocket config module.
      use _ <- result.try(
        write_config(config: config) |> result.map_error(fn(e) { [e] }),
      )

      // Generate client-side type registration (gleam + mjs).
      use _ <- result.try(
        write_v3_register(config: config, discovered: discovered),
      )

      // Generate Erlang atom pre-registration module.
      use _ <- result.try(
        write_atoms(config: config, discovered: discovered)
        |> result.map_error(fn(e) { [e] }),
      )

      Ok(list.length(message_modules))
    }
  }
}

/// Write the client-side type registration files for v3 (gleam wrapper + mjs FFI).
/// Uses the pre-discovered variant list instead of walking from function signatures.
fn write_v3_register(
  config config: Config,
  discovered discovered: List(DiscoveredVariant),
) -> Result(Nil, List(GenError)) {
  use _ <- result.try(
    write_register_gleam(config:) |> result.map_error(fn(e) { [e] }),
  )
  use _ <- result.try(
    write_register_ffi(config:, discovered:) |> result.map_error(fn(e) { [e] }),
  )
  Ok(Nil)
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
    MissingSharedState(expected_path) ->
      "missing server/shared_state.gleam: expected at `"
      <> expected_path
      <> "`"
      <> "\n  create a module exporting the `SharedState` type"
    MissingAppError(expected_path) ->
      "missing server/app_error.gleam: expected at `"
      <> expected_path
      <> "`"
      <> "\n  create a module exporting the `AppError` type"
    MissingHandler(message_module, expected_path) ->
      "missing handler for message module `"
      <> message_module
      <> "`: expected at `"
      <> expected_path
      <> "`"
      <> "\n  create a handler module with a `handle` function"
    NoMessageModules(shared_path) ->
      "no message modules found under `"
      <> shared_path
      <> "`"
      <> "\n  create a shared module exporting a `ToServer` or `ToClient` type"
  }
  io.println_error("error: " <> message)
}

fn format_file_error(err: simplifile.FileError) -> String {
  simplifile.describe_error(err)
}

@external(erlang, "erlang", "halt")
fn halt(code: Int) -> Nil

@external(erlang, "libero_ffi", "trap_signals")
fn trap_signals() -> Nil

// ---------- Config file ----------

fn write_config(config config: Config) -> Result(Nil, GenError) {
  let content = case config.ws_mode {
    WsFullUrl(url:) -> "//// Code generated by libero. DO NOT EDIT.
////
//// WebSocket endpoint the client connects to at runtime.
//// Set via --ws-url at generation time. Rerun bin/dev to regenerate
//// if the URL changes.

pub fn ws_url() -> String {
  \"" <> url <> "\"
}
"
    WsPathOnly(path:) -> "//// Code generated by libero. DO NOT EDIT.
////
//// WebSocket endpoint resolved at runtime from the browser's location.
//// Set via --ws-path at generation time. The scheme (ws/wss) and host
//// are inferred from window.location so one compiled bundle works
//// across all subdomains.

pub fn ws_url() -> String {
  resolve_ws_url(\"" <> path <> "\")
}

@external(javascript, \"./rpc_config_ffi.mjs\", \"resolveWsUrl\")
fn resolve_ws_url(_path: String) -> String {
  panic as \"resolve_ws_url requires a browser environment (window.location)\"
}
"
  }
  let output = config.config_output
  ensure_parent_dir(path: output)
  use _ <- result.try(write_file(path: output, content: content))
  write_config_ffi(config: config)
}

/// Write the rpc_config_ffi.mjs resolver file when --ws-path is active.
fn write_config_ffi(config config: Config) -> Result(Nil, GenError) {
  case config.ws_mode {
    WsFullUrl(..) -> Ok(Nil)
    WsPathOnly(..) -> {
      let ffi_path = string.replace(config.config_output, ".gleam", "_ffi.mjs")
      let ffi_content =
        "// Code generated by libero. DO NOT EDIT.
//
// Resolves a WebSocket URL from the browser's current location + path.
// Used by the generated rpc_config.gleam when --ws-path is active.

export function resolveWsUrl(path) {
  const protocol = globalThis.location?.protocol === \"https:\" ? \"wss:\" : \"ws:\";
  const host = globalThis.location?.host ?? \"localhost\";
  return protocol + \"//\" + host + path;
}
"
      write_file(path: ffi_path, content: ffi_content)
    }
  }
}

/// Write content to a file, logging the path on success.
fn write_file(
  path path: String,
  content content: String,
) -> Result(Nil, GenError) {
  case simplifile.write(path, content) {
    Ok(_) -> {
      io.println("  wrote " <> path)
      Ok(Nil)
    }
    Error(cause) -> Error(CannotWriteFile(path: path, cause: cause))
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
// constructor referenced transitively from message type fields.
//
// The walker starts from the ToServer/ToClient types in each message
// module, then walks each custom type's variant fields transitively to
// discover all types that can appear on the wire.

/// A single discovered variant to emit as a registerConstructor call.
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
      use <- bool.lazy_guard(when: set.contains(visited, key), return: fn() {
        do_walk(
          queue: rest_queue,
          visited: visited,
          discovered: discovered,
          module_files: module_files,
          parsed_cache: parsed_cache,
          errors: errors,
        )
      })
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
  // Resolve file path - if missing, record error and continue
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
  continue_without_errors continue_without_errors: fn(
    Dict(String, glance.Module),
  ) ->
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
  continue_without_errors continue_without_errors: fn(
    Dict(String, glance.Module),
  ) ->
    Result(List(DiscoveredVariant), List(GenError)),
  continue_with_error continue_with_error: fn(
    Dict(String, glance.Module),
    GenError,
  ) ->
    Result(List(DiscoveredVariant), List(GenError)),
) -> Result(List(DiscoveredVariant), List(GenError)) {
  // Check type alias - skip silently
  let is_alias =
    list.any(ast.type_aliases, fn(d) { d.definition.name == type_name })
  use <- bool.lazy_guard(when: is_alias, return: fn() {
    continue_without_errors(new_cache)
  })
  // Find the custom type definition
  case list.find(ast.custom_types, fn(d) { d.definition.name == type_name }) {
    Error(Nil) ->
      continue_with_error(new_cache, TypeNotFound(module_path:, type_name:))
    Ok(ct_def) -> {
      let custom_type = ct_def.definition
      let resolver = build_type_resolver(ast.imports)
      // Collect variants and field type refs
      let #(new_discovered_rev, new_queue_items_rev) =
        list.fold(custom_type.variants, #([], []), fn(acc, variant) {
          let #(disc_acc, queue_acc) = acc
          let float_indices = detect_float_fields(variant.fields)
          let disc_item =
            DiscoveredVariant(
              module_path: module_path,
              variant_name: variant.name,
              atom_name: to_snake_case(variant.name),
              float_field_indices: float_indices,
            )
          let field_refs =
            collect_variant_field_refs(
              variant: variant,
              resolver: resolver,
              current_module: module_path,
              visited: visited,
            )
          #([disc_item, ..disc_acc], list.append(field_refs, queue_acc))
        })
      let new_discovered =
        list.append(discovered, list.reverse(new_discovered_rev))
      let new_queue_items = list.reverse(new_queue_items_rev)
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
      case module_path {
        Error(Nil) -> param_refs
        Ok(mp) -> {
          use <- bool.guard(when: is_skipped_module(mp), return: param_refs)
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
/// Handles consecutive uppercase: "XMLParser" → "xml_parser".
/// Must stay aligned with `snakeCase()` in rpc_ffi.mjs.
fn to_snake_case(name: String) -> String {
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

/// Write the tiny Gleam wrapper that consumers call from main().
fn write_register_gleam(config config: Config) -> Result(Nil, GenError) {
  let content =
    "//// Code generated by libero. DO NOT EDIT.
////
//// Registers every consumer custom type that might cross the wire
//// so libero's client-side rebuild function can reconstruct tagged
//// ETF terms into Gleam class instances. Call register_all() exactly
//// once at client boot, before the first message is sent.

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
    "import { registerConstructor, registerFloatFields } from \""
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
  // Emit registerFloatFields calls for variants with Float-typed fields.
  let float_field_calls =
    list.filter_map(discovered, fn(v) {
      case v.float_field_indices {
        [] -> Error(Nil)
        indices -> {
          let indices_str =
            list.map(indices, int.to_string) |> string.join(", ")
          Ok(
            "  registerFloatFields(\""
            <> v.atom_name
            <> "\", ["
            <> indices_str
            <> "]);",
          )
        }
      }
    })
  let all_calls = list.append(register_calls, float_field_calls)
  let content = "// Code generated by libero. DO NOT EDIT.
//
// Registers every custom type that transitively crosses the wire for
// this namespace's message modules. Walked from ToServer/ToClient types
// at generation time - the consumer does not list types manually.

" <> libero_import <> "\n" <> string.join(module_imports, "\n") <> "\n\nexport function registerAll() {\n" <> string.join(
      all_calls,
      "\n",
    ) <> "\n}\n"
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

/// Generate an Erlang FFI file that pre-registers all constructor atoms
/// discovered by the type graph walker, plus framework atoms used by
/// libero's wire protocol. Calling `ensure/0` from this module creates
/// the atoms in the BEAM atom table so that `binary_to_term([safe])`
/// can decode client ETF payloads without rejecting unknown atoms.
fn write_atoms(
  config config: Config,
  discovered discovered: List(DiscoveredVariant),
) -> Result(Nil, GenError) {
  // Framework atoms that libero's wire protocol uses. These are always
  // needed regardless of which message modules exist.
  let framework_atoms = [
    "ok", "error", "some", "none", "nil", "true", "false", "app_error",
    "malformed_request", "unknown_function", "internal_error", "decode_error",
  ]
  // Collect all unique atom names: framework + discovered variants.
  let discovered_atoms = list.map(discovered, fn(v) { v.atom_name })
  let all_atoms =
    list.append(framework_atoms, discovered_atoms)
    |> list.unique
    |> list.sort(string.compare)
  let atom_list =
    list.map(all_atoms, fn(atom) { "        <<\"" <> atom <> "\">>" })
    |> string.join(",\n")
  let content = "%% Code generated by libero. DO NOT EDIT.
%%
%% Pre-registers all constructor atoms that may appear in client ETF
%% payloads, so binary_to_term([safe]) can decode them without
%% rejecting unknown atoms.
%%
%% ensure/0 uses persistent_term as a one-shot guard so the
%% binary_to_atom calls only run once per VM lifetime.
%%
%% lists:foreach + fun is used instead of bare binary_to_atom calls
%% because the Erlang compiler optimizes away pure BIF calls whose
%% results are discarded.

-module(" <> config.atoms_module <> ").
-export([ensure/0]).

ensure() ->
    case persistent_term:get({?MODULE, done}, false) of
        true -> nil;
        false -> do_ensure()
    end.

do_ensure() ->
    lists:foreach(fun(B) -> binary_to_atom(B) end, [
" <> atom_list <> "
    ]),
    persistent_term:put({?MODULE, done}, true),
    nil.
"
  let output = config.atoms_output
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
  case string.ends_with(entry, ".gleam") {
    True -> [child, ..acc]
    False -> acc
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

// ---------- Dispatch file rendering ----------

/// Create the parent directory for the given file path, ignoring any
/// error. create_directory_all is idempotent (no error if the dir
/// already exists) and any real write failure surfaces on the
/// subsequent simplifile.write call.
fn ensure_parent_dir(path path: String) -> Nil {
  let _discard = simplifile.create_directory_all(extract_dir(path))
  Nil
}

fn extract_dir(path: String) -> String {
  case string.split(path, "/") |> list.reverse {
    [_last, ..rest_rev] -> string.join(list.reverse(rest_rev), "/")
    [] -> "."
  }
}

// ---------- Message module scanner ----------

/// Scan the shared package source directory for modules that export
/// `ToServer` or `ToClient` types. These define the wire contract for
/// the v3 message-type convention.
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
  let has_to_server =
    list.any(parsed.custom_types, fn(ct) {
      let glance.Definition(_, t) = ct
      t.name == "ToServer" && t.publicity == glance.Public
    })
  let has_to_client =
    list.any(parsed.custom_types, fn(ct) {
      let glance.Definition(_, t) = ct
      t.name == "ToClient" && t.publicity == glance.Public
    })
  use <- bool.guard(
    when: !has_to_server && !has_to_client,
    return: Error(Nil),
  )
  let module_path = derive_module_path(file_path: file_path)
  Ok(MessageModule(
    module_path: module_path,
    file_path: file_path,
    has_to_server: has_to_server,
    has_to_client: has_to_client,
  ))
}

/// Derive the Gleam module path from a file path by finding `/src/` and
/// taking everything after it, then stripping the `.gleam` extension.
/// E.g. `examples/todos/shared/src/shared/todos.gleam` -> `shared/todos`.
fn derive_module_path(file_path file_path: String) -> String {
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
/// v3 code generation:
/// 1. `server/shared_state.gleam` exists
/// 2. `server/app_error.gleam` exists
/// 3. For each message module with `has_to_server`, a handler exists at
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
      case m.has_to_server {
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
fn last_module_segment(module_path module_path: String) -> String {
  string.split(module_path, "/")
  |> list.last
  |> result.unwrap(or: module_path)
}

// ---------- v3 type walker ----------

/// Walk the type graph rooted at ToServer/ToClient message types.
/// Seeds the BFS walker from all variants of ToServer and ToClient custom
/// types in each message module, then walks their field types transitively.
///
/// Both the ToServer/ToClient types themselves (and their constructors) and
/// all transitively reachable types are included in the discovered list,
/// since they all need codec registration.
pub fn walk_message_registry_types(
  message_modules message_modules: List(MessageModule),
  module_files module_files: Dict(String, String),
) -> Result(List(DiscoveredVariant), List(GenError)) {
  // Seed the work queue from ToServer and ToClient types in each message module.
  // We also need to seed the walk with the ToServer/ToClient type names
  // themselves so their variants get discovered.
  let seed =
    list.fold(message_modules, set.new(), fn(acc, message_module) {
      use <- bool.guard(
        when: is_skipped_module(message_module.module_path),
        return: acc,
      )
      let with_to_server = case message_module.has_to_server {
        True -> set.insert(acc, #(message_module.module_path, "ToServer"))
        False -> acc
      }
      case message_module.has_to_client {
        True ->
          set.insert(with_to_server, #(message_module.module_path, "ToClient"))
        False -> with_to_server
      }
    })
    |> set.to_list

  do_walk(
    queue: seed,
    visited: set.new(),
    discovered: [],
    module_files: module_files,
    parsed_cache: dict.new(),
    errors: [],
  )
}

// ---------- v3 server dispatch generator ----------

/// Generate the server dispatch module at `server_generated/dispatch.gleam`.
/// The dispatch module decodes incoming wire calls and routes them by module
/// name to the appropriate handler.
pub fn write_v3_dispatch(
  message_modules message_modules: List(MessageModule),
  server_generated server_generated: String,
) -> Result(Nil, GenError) {
  // Only modules with ToServer need dispatch arms.
  let to_server_modules =
    list.filter(message_modules, fn(m) { m.has_to_server })

  // Build handler import aliases: last segment of module_path.
  // e.g. "shared/todos" -> alias "todos_handler", import "server/handlers/todos"
  let handler_imports =
    list.map(to_server_modules, fn(m) {
      let segment = last_module_segment(module_path: m.module_path)
      "import server/handlers/" <> segment <> " as " <> segment <> "_handler"
    })

  // Build the case arms for the dispatch function.
  let case_arms =
    list.map(to_server_modules, fn(m) {
      let segment = last_module_segment(module_path: m.module_path)
      "    Ok(#(\""
      <> m.module_path
      <> "\", msg)) ->\n      dispatch(fn() { "
      <> segment
      <> "_handler.handle(msg: wire.coerce(msg), state:) })"
    })

  let ok_unknown_arm =
    "    Ok(#(name, _)) ->\n      #(wire.encode(Error(UnknownFunction(name))), None)"

  let error_arm =
    "    Error(_) ->\n      #(wire.encode(Error(MalformedRequest)), None)"

  let all_arms = list.flatten([case_arms, [ok_unknown_arm, error_arm]])

  let content =
    "//// Code generated by libero. DO NOT EDIT.

import gleam/option.{type Option, None, Some}
import libero/error.{type PanicInfo, InternalError, MalformedRequest, UnknownFunction}
import libero/trace
import libero/wire
import server/app_error.{type AppError}
import server/shared_state.{type SharedState}
"
    <> string.join(handler_imports, "\n")
    <> "

pub fn handle(
  state state: SharedState,
  data data: BitArray,
) -> #(BitArray, Option(PanicInfo)) {
  case wire.decode_call(data) {
"
    <> string.join(all_arms, "\n")
    <> "
  }
}

fn dispatch(
  call call: fn() -> Result(a, AppError),
) -> #(BitArray, Option(PanicInfo)) {
  case trace.try_call(call) {
    Ok(Ok(value)) -> #(wire.encode(Ok(value)), None)
    Ok(Error(app_err)) -> #(wire.encode(Error(error.AppError(app_err))), None)
    Error(reason) -> {
      let trace_id = trace.new_trace_id()
      #(
        wire.encode(Error(InternalError(trace_id, \"Internal server error\"))),
        Some(error.PanicInfo(trace_id:, fn_name: \"dispatch\", reason:)),
      )
    }
  }
}
"

  let output = server_generated <> "/dispatch.gleam"
  ensure_parent_dir(path: output)
  case simplifile.write(output, content) {
    Ok(_) -> {
      io.println("  wrote " <> output)
      Ok(Nil)
    }
    Error(cause) -> Error(CannotWriteFile(path: output, cause: cause))
  }
}

// ---------- v3 client send function generator ----------

/// Generate per-module send function files under `client_generated/`.
/// For each message module with `has_to_server == True`, generates a
/// `<module_name>.gleam` file with a `send` function that wraps `rpc.send`.
pub fn write_v3_send_functions(
  message_modules message_modules: List(MessageModule),
  client_generated client_generated: String,
) -> Result(Nil, List(GenError)) {
  let to_server_modules =
    list.filter(message_modules, fn(m) { m.has_to_server })

  let errors =
    list.fold(to_server_modules, [], fn(errs, m) {
      let segment = last_module_segment(module_path: m.module_path)
      let content =
        "//// Code generated by libero. DO NOT EDIT.

import gleam/dynamic.{type Dynamic}
import "
        <> m.module_path
        <> ".{type ToServer}
import libero/rpc
import client/generated/libero/rpc_config
import lustre/effect.{type Effect}

pub fn send(
  msg msg: ToServer,
  on_response on_response: fn(Dynamic) -> msg,
) -> Effect(msg) {
  rpc.send(
    url: rpc_config.ws_url(),
    module: \""
        <> m.module_path
        <> "\",
    msg: msg,
    on_response: on_response,
  )
}
"
      let output = client_generated <> "/" <> segment <> ".gleam"
      ensure_parent_dir(path: output)
      case simplifile.write(output, content) {
        Ok(_) -> {
          io.println("  wrote " <> output)
          errs
        }
        Error(cause) -> [CannotWriteFile(path: output, cause: cause), ..errs]
      }
    })

  case errors {
    [] -> Ok(Nil)
    _ -> Error(list.reverse(errors))
  }
}
