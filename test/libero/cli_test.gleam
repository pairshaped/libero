import libero

pub fn find_flag_present_test() {
  let args = ["--ws-url=wss://example.com/ws", "--shared=../shared"]
  let assert Ok("wss://example.com/ws") =
    libero.find_flag(args: args, name: "--ws-url")
}

pub fn find_flag_missing_test() {
  let args = ["--ws-url=wss://example.com/ws"]
  let assert Error(Nil) = libero.find_flag(args: args, name: "--shared")
}

pub fn find_flag_empty_value_test() {
  let args = ["--ws-url="]
  let assert Ok("") = libero.find_flag(args: args, name: "--ws-url")
}

pub fn find_flag_value_with_equals_test() {
  let args = ["--ws-url=wss://example.com/ws?key=value"]
  let assert Ok("wss://example.com/ws?key=value") =
    libero.find_flag(args: args, name: "--ws-url")
}

pub fn find_flag_empty_args_test() {
  let assert Error(Nil) = libero.find_flag(args: [], name: "--ws-url")
}

pub fn find_flag_partial_match_not_found_test() {
  let args = ["--ws-url-extra=foo"]
  let assert Error(Nil) = libero.find_flag(args: args, name: "--ws-url")
}
