//// Shared validation for CLI commands (project names, client names, etc.).

import gleam/list
import gleam/string

const lowercase_letters = "abcdefghijklmnopqrstuvwxyz"

const digits = "0123456789"

pub fn is_lowercase_letter(ch: String) -> Bool {
  string.contains(lowercase_letters, ch)
}

pub fn is_digit(ch: String) -> Bool {
  string.contains(digits, ch)
}

/// Gleam reserved words that cannot be used as project or client names.
const reserved_words = [
  "as", "assert", "auto", "case", "const", "external", "fn", "if", "import",
  "let", "macro", "opaque", "panic", "pub", "test", "todo", "type", "use",
]

/// Validate a name for use as a project or client name.
/// Returns Ok(Nil) if valid, Error(String) with a user-facing error message if not.
/// nolint: stringly_typed_error -- CLI-facing error, String is appropriate
pub fn validate_name(
  name name: String,
  kind kind: String,
  hint hint: String,
) -> Result(Nil, String) {
  case string.to_graphemes(name) {
    [] -> Error("error: Invalid " <> kind <> " name
  \u{2502}
  \u{2502} " <> kind_cap(kind) <> " name cannot be empty
  \u{2502}
  hint: " <> hint)
    [first, ..rest] ->
      case is_lowercase_letter(first) {
        False -> Error("error: Invalid " <> kind <> " name: `" <> name <> "`
  \u{2502}
  \u{2502} Must start with a lowercase letter (a-z)
  \u{2502}
  hint: Try `" <> string.lowercase(name) <> "` instead")
        True ->
          case
            list.all(rest, fn(ch) {
              is_lowercase_letter(ch) || is_digit(ch) || ch == "_"
            })
          {
            False -> Error("error: Invalid " <> kind <> " name: `" <> name <> "`
  \u{2502}
  \u{2502} Must contain only lowercase letters, digits, and underscores")
            True ->
              case list.contains(reserved_words, name) {
                True ->
                  Error("error: Invalid " <> kind <> " name: `" <> name <> "`
  \u{2502}
  \u{2502} `" <> name <> "` is a Gleam reserved word
  \u{2502}
  hint: Choose a different name")
                False -> Ok(Nil)
              }
          }
      }
  }
}

fn kind_cap(kind: String) -> String {
  case kind {
    "project" -> "Project"
    "client" -> "Client"
    _ -> kind
  }
}
