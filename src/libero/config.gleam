import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

// ---------- Types ----------

/// Errors from config construction (invalid namespace, etc.).
pub type ConfigError {
  InvalidNamespace(namespace: String)
}

/// Format a ConfigError as a user-facing error message.
pub fn describe_error(error: ConfigError) -> String {
  let InvalidNamespace(namespace: ns) = error
  "error: Invalid namespace: `" <> ns <> "`
  \u{2502}
  \u{2502} Namespace must contain only lowercase letters, digits, and underscores
  \u{2502}
  hint: gleam run -m libero"
}

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
) -> Result(Config, ConfigError) {
  use namespace <- result.try(validate_namespace(namespace))
  // In the final JS bundle, decoder files land at:
  //   build/dev/javascript/<client_pkg>/generated/[<ns>/]rpc_decoders_ffi.mjs
  // So from the ffi file's directory, the bundle root is:
  //   - 2 levels up for no-namespace (generated/)
  //   - 3 levels up for namespaced   (generated/<ns>/)
  let #(
    atoms_output,
    atoms_module,
    config_output,
    register_relpath_prefix,
    decoders_ffi_output,
    decoders_gleam_output,
  ) = case namespace {
    None -> #(
      "src/generated@libero@rpc_atoms.erl",
      "generated@libero@rpc_atoms",
      client_root <> "/src/generated/rpc_config.gleam",
      "../../",
      client_root <> "/src/generated/rpc_decoders_ffi.mjs",
      client_root <> "/src/generated/rpc_decoders.gleam",
    )
    Some(ns) -> #(
      "src/generated@libero@" <> ns <> "@rpc_atoms.erl",
      "generated@libero@" <> ns <> "@rpc_atoms",
      client_root <> "/src/generated/" <> ns <> "/rpc_config.gleam",
      "../../../",
      client_root <> "/src/generated/" <> ns <> "/rpc_decoders_ffi.mjs",
      client_root <> "/src/generated/" <> ns <> "/rpc_decoders.gleam",
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
    None -> "src/generated/libero"
    Some(ns) -> "src/generated/libero/" <> ns
  }
  let client_generated = case namespace {
    None -> client_root <> "/src/generated"
    Some(ns) -> client_root <> "/src/generated/" <> ns
  }
  let decoders_prelude_import_path =
    register_relpath_prefix <> "libero/libero/decoders_prelude.mjs"
  Ok(Config(
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
  ))
}

/// Return a copy of `config` whose output paths are rooted at `project_path`.
///
/// `to_codegen_config` builds a Config with paths relative to the project
/// root. The codegen functions write at those paths via `simplifile`, which
/// resolves them against CWD. When the caller (typically `cli/gen.run`) is
/// driving codegen against a project at a path other than CWD, the writes
/// land in the wrong place. This helper rewrites the output fields so they
/// resolve correctly regardless of CWD.
///
/// Input paths (`shared_src`, `server_src`) are NOT prefixed: `gen.run`
/// already resolves those before scanning.
///
/// `atoms_module`, `register_relpath_prefix`, `decoders_prelude_import_path`,
/// and `client_root` are NOT prefixed: they're not filesystem paths the
/// codegen writes to.
pub fn prefix_paths(
  config config: Config,
  project_path project_path: String,
) -> Config {
  let prefix = fn(path) { project_path <> "/" <> path }
  Config(
    ..config,
    atoms_output: prefix(config.atoms_output),
    config_output: prefix(config.config_output),
    decoders_ffi_output: prefix(config.decoders_ffi_output),
    decoders_gleam_output: prefix(config.decoders_gleam_output),
    server_generated: prefix(config.server_generated),
    client_generated: prefix(config.client_generated),
  )
}

/// Validate that a namespace (if present) contains only lowercase letters,
/// digits, and underscores, and starts with a letter.
/// Returns the namespace unchanged on success, or a formatted error string.
fn validate_namespace(
  namespace: Option(String),
) -> Result(Option(String), ConfigError) {
  case namespace {
    None -> Ok(None)
    Some(ns) -> {
      let graphemes = string.to_graphemes(ns)
      let is_valid = case graphemes {
        [] -> False
        [first, ..rest] ->
          string.contains("abcdefghijklmnopqrstuvwxyz", first)
          && list.all(rest, fn(ch) {
            string.contains("abcdefghijklmnopqrstuvwxyz", ch)
            || string.contains("0123456789", ch)
            || ch == "_"
          })
      }
      case is_valid {
        True -> Ok(Some(ns))
        False -> Error(InvalidNamespace(namespace: ns))
      }
    }
  }
}
