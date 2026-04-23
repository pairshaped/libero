import gleam/option.{None, Some}
import libero/cli

pub fn parse_new_no_database_test() {
  let assert cli.New(name: "my_app", database: None) =
    cli.parse_args(["new", "my_app"])
}

pub fn parse_new_pg_test() {
  let assert cli.New(name: "my_app", database: Some(cli.Postgres)) =
    cli.parse_args(["new", "my_app", "--database", "pg"])
}

pub fn parse_new_sqlite_test() {
  let assert cli.New(name: "my_app", database: Some(cli.Sqlite)) =
    cli.parse_args(["new", "my_app", "--database", "sqlite"])
}

pub fn parse_new_invalid_database_test() {
  let assert cli.Unknown =
    cli.parse_args(["new", "my_app", "--database", "mongo"])
}

pub fn parse_new_database_missing_value_test() {
  let assert cli.Unknown = cli.parse_args(["new", "my_app", "--database"])
}
