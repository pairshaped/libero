// ---------- Types ----------

/// Everything libero needs to drive a single client's codegen output.
/// Built by `toml_config.to_codegen_config` from gleam.toml.
pub type Config {
  Config(
    /// Path-only WebSocket route. The generated client resolves it
    /// against `window.location` at boot, which lets multi-tenant
    /// deployments share one bundle across subdomains.
    ws_path: String,
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
    server_generated: String,
    client_generated: String,
  )
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
/// `atoms_module`, `register_relpath_prefix`, `decoders_prelude_import_path`
/// are NOT prefixed: they're not filesystem paths the codegen writes to.
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
