import argv
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

// ---------- Types ----------

/// How the generated client resolves its WebSocket URL.
pub type WsMode {
  /// Hardcoded full URL (from --ws-url). Single-host deployments.
  WsFullUrl(url: String)
  /// Path-only, resolved at runtime from window.location (from --ws-path).
  /// Multi-tenant deployments where multiple subdomains share one bundle.
  WsPathOnly(path: String)
}

/// Everything libero needs from its invocation args, normalized.
/// Paths are derived from --namespace and --client with single-SPA
/// defaults when those flags are absent.
pub type Config {
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
    /// Bundle-relative prefix that prepends every import in the
    /// generated FFI .mjs file. Depth depends on where the decoder
    /// files land inside the consumer client package.
    register_relpath_prefix: String,
    /// Path to the generated rpc_decoders_ffi.mjs file.
    decoders_ffi_output: String,
    /// Path to the generated rpc_decoders.gleam wrapper file.
    decoders_gleam_output: String,
    /// Import path the generated decoders FFI uses to pull from the
    /// static decoders_prelude.mjs shipped with libero.
    decoders_prelude_import_path: String,
    shared_src: option.Option(String),
    server_src: option.Option(String),
    server_generated: String,
    client_generated: String,
  )
}

// ---------- External ----------

@external(erlang, "erlang", "halt")
fn halt(code: Int) -> Nil

// ---------- Config parsing ----------

pub fn parse_config() -> Config {
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
  // --shared= and --server= enable message-module mode.
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
pub fn build_config(
  ws_mode ws_mode: WsMode,
  namespace namespace: option.Option(String),
  client_root client_root: String,
  shared_root shared_root: Result(String, Nil),
  server_root server_root: Result(String, Nil),
) -> Config {
  // In the final JS bundle, decoder files land at:
  //   <bundle_root>/<client_pkg>/client/generated/libero/[<ns>/]rpc_decoders_ffi.mjs
  // So from the ffi file's directory, the bundle root is:
  //   - 4 levels up for no-namespace (client_pkg/client/generated/libero/)
  //   - 5 levels up for namespaced  (client_pkg/client/generated/libero/<ns>/)
  let #(
    atoms_output,
    atoms_module,
    config_output,
    register_relpath_prefix,
    decoders_ffi_output,
    decoders_gleam_output,
  ) = case namespace {
    None -> #(
      "src/server@generated@libero@rpc_atoms.erl",
      "server@generated@libero@rpc_atoms",
      client_root <> "/src/client/generated/libero/rpc_config.gleam",
      "../../../../",
      client_root <> "/src/client/generated/libero/rpc_decoders_ffi.mjs",
      client_root <> "/src/client/generated/libero/rpc_decoders.gleam",
    )
    Some(ns) -> #(
      "src/server@generated@libero@" <> ns <> "@rpc_atoms.erl",
      "server@generated@libero@" <> ns <> "@rpc_atoms",
      client_root
        <> "/src/client/generated/libero/"
        <> ns
        <> "/rpc_config.gleam",
      "../../../../../",
      client_root
        <> "/src/client/generated/libero/"
        <> ns
        <> "/rpc_decoders_ffi.mjs",
      client_root
        <> "/src/client/generated/libero/"
        <> ns
        <> "/rpc_decoders.gleam",
    )
  }
  // Paths derived from --shared and --server flags.
  // shared_src = <shared_root>/src/shared  (the shared package's module src dir)
  // server_src = <server_root>/src         (the server package's src dir)
  // server_generated and client_generated are where dispatch.gleam and
  // client send stubs are written, matching the convention used by the consumer.
  let shared_src: Option(String) =
    shared_root
    |> result.map(fn(root) { root <> "/src/shared" })
    |> option.from_result
  let server_src: Option(String) =
    server_root
    |> result.map(fn(root) { root <> "/src" })
    |> option.from_result
  let server_generated = case namespace {
    None -> "src/server/generated/libero"
    Some(ns) -> "src/server/generated/libero/" <> ns
  }
  let client_generated = case namespace {
    None -> client_root <> "/src/client/generated/libero"
    Some(ns) -> client_root <> "/src/client/generated/libero/" <> ns
  }
  let decoders_prelude_import_path =
    register_relpath_prefix <> "libero/libero/decoders_prelude.mjs"
  Config(
    ws_mode: ws_mode,
    namespace: namespace,
    client_root: client_root,
    atoms_output: atoms_output,
    atoms_module: atoms_module,
    config_output: config_output,
    register_relpath_prefix: register_relpath_prefix,
    decoders_ffi_output: decoders_ffi_output,
    decoders_gleam_output: decoders_gleam_output,
    decoders_prelude_import_path: decoders_prelude_import_path,
    shared_src: shared_src,
    server_src: server_src,
    server_generated: server_generated,
    client_generated: client_generated,
  )
}

/// Extract a `--name=value` flag from the argument list.
pub fn find_flag(
  args args: List(String),
  name name: String,
) -> Result(String, Nil) {
  let prefix = name <> "="
  args
  |> list.find(fn(arg) { string.starts_with(arg, prefix) })
  |> result.map(fn(arg) { string.drop_start(arg, string.length(prefix)) })
}
