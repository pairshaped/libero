//// Run `gleam format` on generated Gleam code.
////
//// Writes code to a temp file, runs the formatter, reads back the result.
//// Falls back to the original string if formatting fails.

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
  let #(exit_code, output) = run_format_command(tmp)
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
      case string.trim(output) {
        "" -> Nil
        trimmed -> io.println_error("  " <> trimmed)
      }
      fallback
    }
  }
}

fn run_format_command(tmp: String) -> #(Int, String) {
  case find_executable("gleam") {
    option.None -> #(-1, "gleam executable not found on PATH")
    option.Some(path) -> run_executable_capturing_ffi(path, ["format", tmp])
  }
}

@external(erlang, "libero_cli_ffi", "run_executable_capturing")
fn run_executable_capturing_ffi(
  path: String,
  args: List(String),
) -> #(Int, String)

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

// Wraps os:getenv/1 with charlist↔binary conversion. We can't call
// os:getenv/1 directly with a Gleam String because OTP 27 raises badarg
// when the argument is a binary rather than a charlist.
@external(erlang, "libero_cli_ffi", "get_env")
fn get_env(name: String) -> Option(String)
