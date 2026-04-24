import gleam/option.{None, Some}
import gleam/result
import gleam/string
import libero/cli
import libero/cli/new as cli_new
import simplifile

pub fn scaffold_project_test() {
  let dir = "build/.test_cli_new/test_scaffold"
  let _ = simplifile.delete("build/.test_cli_new")

  let assert Ok(Nil) = cli_new.scaffold(path: dir, database: None)

  let assert Ok(True) = simplifile.is_file(dir <> "/gleam.toml")
  let assert Ok(True) = simplifile.is_directory(dir <> "/src/server")
  let assert Ok(True) = simplifile.is_directory(dir <> "/shared/src/shared")

  let assert Ok(gleam_toml) = simplifile.read(dir <> "/gleam.toml")
  let assert True = string.contains(gleam_toml, "name = \"test_scaffold\"")
  let assert True = string.contains(gleam_toml, "target = \"erlang\"")
  let assert True = string.contains(gleam_toml, "[tools.libero]")
  let assert True = string.contains(gleam_toml, "shared = { path = \"shared\"")

  // No database deps when no flag
  let assert False = string.contains(gleam_toml, "pog")
  let assert False = string.contains(gleam_toml, "sqlight")

  let assert Ok(True) = simplifile.is_file(dir <> "/shared/gleam.toml")
  let assert Ok(True) =
    simplifile.is_file(dir <> "/shared/src/shared/messages.gleam")
  let assert Ok(True) = simplifile.is_file(dir <> "/src/server/handler.gleam")
  let assert Ok(True) =
    simplifile.is_file(dir <> "/src/server/shared_state.gleam")
  let assert Ok(True) =
    simplifile.is_file(dir <> "/test/test_scaffold_test.gleam")
  let assert Ok(True) = simplifile.is_file(dir <> "/README.md")

  // No db.gleam or sql dir when no database flag
  let assert Ok(False) = simplifile.is_file(dir <> "/src/server/db.gleam")

  let _ = simplifile.delete("build/.test_cli_new")
  Nil
}

pub fn scaffold_pg_test() {
  let dir = "build/.test_cli_new/test_pg"
  let _ = simplifile.delete("build/.test_cli_new")

  let assert Ok(Nil) = cli_new.scaffold(path: dir, database: Some(cli.Postgres))

  let assert Ok(gleam_toml) = simplifile.read(dir <> "/gleam.toml")
  let assert True = string.contains(gleam_toml, "pog")
  let assert True = string.contains(gleam_toml, "squirrel")
  let assert False = string.contains(gleam_toml, "sqlight")
  let assert False = string.contains(gleam_toml, "[tools.marmot]")

  let assert Ok(True) = simplifile.is_file(dir <> "/src/server/db.gleam")
  let assert Ok(True) = simplifile.is_directory(dir <> "/src/server/sql")

  let assert Ok(db_gleam) = simplifile.read(dir <> "/src/server/db.gleam")
  let assert True = string.contains(db_gleam, "import pog")

  let assert Ok(shared_state) =
    simplifile.read(dir <> "/src/server/shared_state.gleam")
  let assert True = string.contains(shared_state, "pog.Connection")

  let assert Ok(readme) = simplifile.read(dir <> "/README.md")
  let assert True = string.contains(readme, "squirrel")

  let _ = simplifile.delete("build/.test_cli_new")
  Nil
}

pub fn scaffold_empty_name_test() {
  let result = cli_new.scaffold(path: "", database: None)
  let assert True = result.is_error(result)
  let assert Error(msg) = result
  let assert True = string.contains(msg, "name cannot be empty")
}

pub fn scaffold_digit_start_name_test() {
  let result = cli_new.scaffold(path: "123bad", database: None)
  let assert True = result.is_error(result)
  let assert Error(msg) = result
  let assert True = string.contains(msg, "Must start with a lowercase letter")
}

pub fn scaffold_reserved_word_name_test() {
  let result = cli_new.scaffold(path: "type", database: None)
  let assert True = result.is_error(result)
  let assert Error(msg) = result
  let assert True = string.contains(msg, "reserved word")
}

pub fn scaffold_special_chars_name_test() {
  let result = cli_new.scaffold(path: "my-app", database: None)
  let assert True = result.is_error(result)
  let assert Error(msg) = result
  let assert True =
    string.contains(msg, "only lowercase letters, digits, and underscores")
}

pub fn scaffold_sqlite_test() {
  let dir = "build/.test_cli_new/test_sqlite"
  let _ = simplifile.delete("build/.test_cli_new")

  let assert Ok(Nil) = cli_new.scaffold(path: dir, database: Some(cli.Sqlite))

  let assert Ok(gleam_toml) = simplifile.read(dir <> "/gleam.toml")
  let assert True = string.contains(gleam_toml, "sqlight")
  let assert True = string.contains(gleam_toml, "marmot")
  let assert True = string.contains(gleam_toml, "logging")
  let assert True = string.contains(gleam_toml, "[tools.marmot]")
  let assert True = string.contains(gleam_toml, "query_function")
  let assert False = string.contains(gleam_toml, "pog")

  let assert Ok(True) = simplifile.is_file(dir <> "/src/server/db.gleam")
  let assert Ok(True) = simplifile.is_directory(dir <> "/src/server/sql")

  let assert Ok(db_gleam) = simplifile.read(dir <> "/src/server/db.gleam")
  let assert True = string.contains(db_gleam, "import sqlight")
  let assert True = string.contains(db_gleam, "PRAGMA journal_mode")
  let assert True = string.contains(db_gleam, "pub fn query(")

  let assert Ok(shared_state) =
    simplifile.read(dir <> "/src/server/shared_state.gleam")
  let assert True = string.contains(shared_state, "sqlight.Connection")

  let assert Ok(readme) = simplifile.read(dir <> "/README.md")
  let assert True = string.contains(readme, "marmot")

  let _ = simplifile.delete("build/.test_cli_new")
  Nil
}
