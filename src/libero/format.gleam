//// Run `gleam format` on generated Gleam code.
////
//// Writes code to a temp file, runs the formatter, reads back the result.
//// Falls back to the original string if formatting fails.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/io
import gleam/option.{type Option}
import gleam/result
import gleam/string
import simplifile

/// Format a string of Gleam code using `gleam format`.
/// Returns the formatted code, or the original if formatting fails.
/// nolint: thrown_away_error -- intentional fallback: formatting is best-effort
pub fn format_gleam(code: String) -> String {
  let suffix =
    int.to_string(int.absolute_value(unique_integer()))
    <> "_"
    <> int.to_string(random_integer(999_999))
  let tmp_dir = get_tmp_dir()
  let tmp = tmp_dir <> "/libero_fmt_" <> suffix <> ".gleam"
  case simplifile.write(tmp, code) {
    Error(_) -> {
      io.println_error(
        "warning: could not write temp file for formatting, skipping gleam format",
      )
      code
    }
    Ok(_) -> {
      let formatted = run_format(tmp, code)
      // nolint: discarded_result -- cleanup is best-effort
      let _ = simplifile.delete(tmp)
      formatted
    }
  }
}

fn run_format(tmp: String, fallback: String) -> String {
  let exit_code = run_executable("gleam", ["format", tmp])
  case exit_code {
    0 ->
      simplifile.read(tmp)
      |> result.unwrap(fallback)
    _ -> {
      io.println_error(
        "warning: gleam format failed (exit code "
        <> int.to_string(exit_code)
        <> "), using unformatted output",
      )
      fallback
    }
  }
}

fn run_executable(executable: String, args: List(String)) -> Int {
  case find_executable(executable) {
    option.None -> -1
    option.Some(path) -> run_executable_ffi(path, args)
  }
}

@external(erlang, "libero_cli_ffi", "run_executable")
fn run_executable_ffi(path: String, args: List(String)) -> Int

@external(erlang, "libero_cli_ffi", "find_executable")
fn find_executable(name: String) -> Option(String)

@external(erlang, "erlang", "unique_integer")
fn unique_integer() -> Int

@external(erlang, "rand", "uniform")
fn random_integer(max: Int) -> Int

fn get_tmp_dir() -> String {
  get_env("TMPDIR")
  |> option.lazy_or(fn() { get_env("TMP") })
  |> option.lazy_or(fn() { get_env("TEMP") })
  |> option.unwrap("/tmp")
}

// Uses os:getenv/0 + linear scan rather than os:getenv/1, because on OTP 27
// the /1 variant requires a charlist argument and crashes with badarg when
// passed a Gleam String (binary).
@external(erlang, "os", "getenv")
fn getenv_list_ffi() -> Dynamic

/// nolint: thrown_away_error -- env var lookup failure is expected (var not set)
fn get_env(name: String) -> Option(String) {
  let raw = getenv_list_ffi()
  case decode.run(raw, decode.list(decode.string)) {
    Ok(entries) -> find_env(entries, name <> "=")
    Error(_) -> option.None
  }
}

fn find_env(entries: List(String), prefix: String) -> Option(String) {
  case entries {
    [] -> option.None
    [entry, ..rest] ->
      case string.starts_with(entry, prefix) {
        True -> option.Some(string.drop_start(entry, string.length(prefix)))
        False -> find_env(rest, prefix)
      }
  }
}
