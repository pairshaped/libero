//// Cross-cutting helpers used by every codegen submodule.
////
//// File I/O, path utilities, naming helpers, and small predicates over
//// `field_type.FieldType` graphs. The actual generators live in the
//// per-domain modules (codegen_dispatch, codegen_stubs, codegen_decoders,
//// codegen_server).

import gleam/io
import gleam/list
import gleam/result
import gleam/string
import libero/field_type
import libero/format
import libero/gen_error.{type GenError, CannotWriteFile}
import libero/scanner
import simplifile

// SAFETY NOTE: Module paths interpolated into generated code come from
// the scanner, which derives them from filesystem directory names under
// the shared_src root. The scanner's walk_directory filters out non-Gleam
// files and skips symlinks/generated dirs (scanner.gleam lines 265-285).
// Gleam's module naming convention (lowercase + underscores) means these
// paths cannot contain quotes, backslashes, or other injection-relevant
// characters. If the scanner is ever extended to accept paths from
// external input, add explicit validation (e.g. reject paths not matching
// ^[a-z][a-z0-9_]*(/[a-z][a-z0-9_]*)*$).

// ---------- File utilities ----------

/// Write content to a file, logging the path on success.
/// Gleam files are run through `gleam format` before writing.
pub fn write_file(
  path path: String,
  content content: String,
) -> Result(Nil, GenError) {
  let formatted = case string.ends_with(path, ".gleam") {
    True -> format.format_gleam(content)
    False -> content
  }
  case simplifile.write(path, formatted) {
    Ok(_) -> {
      io.println("  wrote " <> path)
      Ok(Nil)
    }
    Error(cause) -> Error(CannotWriteFile(path: path, cause: cause))
  }
}

/// Create the parent directory for the given file path, ignoring any
/// error. create_directory_all is idempotent (no error if the dir
/// already exists) and any real write failure surfaces on the
/// subsequent simplifile.write call.
pub fn ensure_parent_dir(path path: String) -> Nil {
  let _discard = simplifile.create_directory_all(extract_dir(path))
  Nil
}

/// Strip the final path segment, returning the directory portion of `path`.
/// Returns "." when there's no parent (single-segment input).
pub fn extract_dir(path: String) -> String {
  case string.split(path, "/") |> list.reverse {
    [_last, ..rest_rev] ->
      case rest_rev {
        [] -> "."
        _ -> string.join(list.reverse(rest_rev), "/")
      }
    [] -> "."
  }
}

/// Take the substring after the LAST occurrence of `separator` in `input`.
/// Falls back to `input` if the separator is absent. Splitting on the last
/// occurrence (not the first) matters for nested paths like
/// `vendor/x/src/inner/src/types`, where the leftmost match would yield the
/// wrong segment.
pub fn last_split(input input: String, separator separator: String) -> String {
  case string.split(input, separator) {
    [_only] -> input
    parts -> list.last(parts) |> result.unwrap(or: input)
  }
}

/// Convert a Gleam module path like "shared/discount" to its compiled
/// .mjs bundle path "shared/shared/discount.mjs". The first segment
/// is the package name (Gleam convention) and is repeated because
/// the bundle layout is `<package>/<module_path>.mjs`.
pub fn module_to_mjs_path(module_path: String) -> String {
  case string.split_once(module_path, "/") {
    // Single-segment module path: the whole thing IS the package name
    // and its root module, e.g. "shared" → "shared/shared.mjs".
    Error(Nil) -> module_path <> "/" <> module_path <> ".mjs"
    // Multi-segment: first segment is package, the whole path is
    // repeated under it, e.g. "shared/discount" → "shared/shared/discount.mjs".
    Ok(#(package, _)) -> package <> "/" <> module_path <> ".mjs"
  }
}

// ---------- Naming ----------

/// Convert a Gleam module path like "shared/discount" to a flat
/// underscore-separated alias suitable for use as a Gleam identifier
/// or import alias suffix. e.g. "shared/discount" -> "shared_discount".
pub fn module_to_underscored(module_path: String) -> String {
  string.replace(module_path, "/", "_")
}

/// Convert a snake_case name to PascalCase.
/// e.g. "get_items" -> "GetItems", "create_item" -> "CreateItem"
pub fn to_pascal_case(name: String) -> String {
  name
  |> string.split("_")
  |> list.map(fn(word) {
    case string.pop_grapheme(word) {
      Ok(#(first, rest)) -> string.uppercase(first) <> rest
      Error(Nil) -> word
    }
  })
  |> string.join("")
}

// ---------- FieldType predicates over endpoints ----------

/// True if any endpoint's parameter or return type (transitively)
/// satisfies `predicate`. Used for stdlib import detection
/// (Option, Dict).
pub fn endpoints_contain(
  endpoints endpoints: List(scanner.HandlerEndpoint),
  predicate predicate: fn(field_type.FieldType) -> Bool,
) -> Bool {
  list.any(endpoints, fn(e) {
    field_type.contains(e.return_type, predicate)
    || list.any(e.params, fn(p) { field_type.contains(p.1, predicate) })
  })
}

/// Emit a constructor / pattern shape like `Variant(label1:, label2:)` or
/// just `Variant` when there are no parameters. Used by both the dispatch
/// match arms (destructure) and client stubs (constructor call).
pub fn variant_pattern(
  variant_name variant_name: String,
  params params: List(#(String, field_type.FieldType)),
) -> String {
  case params {
    [] -> variant_name
    _ -> {
      let labels = list.map(params, fn(p) { p.0 <> ":" })
      variant_name <> "(" <> string.join(labels, ", ") <> ")"
    }
  }
}

/// Emit the body lines of the generated `ClientMsg` type — one variant
/// per endpoint, indented by two spaces. Both the server dispatch and
/// the client stubs need this exact shape; routing both through this
/// helper guarantees they stay in sync (mismatched variants would
/// silently break the wire contract).
pub fn emit_client_msg_variants(
  endpoints endpoints: List(scanner.HandlerEndpoint),
) -> List(String) {
  list.map(endpoints, fn(e) {
    let variant_name = to_pascal_case(e.fn_name)
    case e.params {
      [] -> "  " <> variant_name
      params -> {
        let fields =
          list.map(params, fn(p) {
            let #(label, ft) = p
            label <> ": " <> field_type.to_gleam_source(ft)
          })
        "  " <> variant_name <> "(" <> string.join(fields, ", ") <> ")"
      }
    }
  })
}

/// Collect `import <module>` lines for every shared module path
/// referenced (transitively) by the endpoints' parameter types and,
/// optionally, return types. Output is unique and sorted.
pub fn collect_endpoint_type_imports(
  endpoints endpoints: List(scanner.HandlerEndpoint),
  include_return include_return: Bool,
) -> List(String) {
  endpoints
  |> list.flat_map(fn(e) {
    let from_params =
      list.flat_map(e.params, fn(p) { field_type.collect_user_types(p.1) })
    case include_return {
      True ->
        list.append(from_params, field_type.collect_user_types(e.return_type))
      False -> from_params
    }
  })
  |> list.map(fn(ref) { ref.0 })
  |> list.unique()
  |> list.sort(string.compare)
  |> list.map(fn(mod) { "import " <> mod })
}

pub fn is_dict(ft: field_type.FieldType) -> Bool {
  case ft {
    field_type.DictOf(_, _) -> True
    _ -> False
  }
}

pub fn is_option(ft: field_type.FieldType) -> Bool {
  case ft {
    field_type.OptionOf(_) -> True
    _ -> False
  }
}
