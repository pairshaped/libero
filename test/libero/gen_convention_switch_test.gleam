//// Tests for the convention-switch logic in `cli/gen`.
////
//// `is_no_message_modules_only` decides whether `gen.run` falls through
//// to the handler-as-contract convention or surfaces a real scan error.
//// Get this wrong and the user gets either "no message modules" when
//// they meant to use endpoint convention, or a confusing
//// "endpoint scan failed" when their shared dir is just misconfigured.

import gleam/list
import libero/cli/gen
import libero/gen_error
import simplifile

pub fn empty_errors_is_vacuously_true_test() {
  // Reachable only via misuse — the call site only invokes this on the
  // Error branch, which always carries at least one error. Documented
  // for future readers.
  let assert True = gen.is_no_message_modules_only([])
}

pub fn single_no_message_modules_is_true_test() {
  let errors = [gen_error.NoMessageModules(shared_path: "shared/src/shared")]
  let assert True = gen.is_no_message_modules_only(errors)
}

pub fn cannot_read_dir_is_false_test() {
  let errors = [
    gen_error.CannotReadDir(path: "shared/src/shared", cause: simplifile.Enoent),
  ]
  let assert False = gen.is_no_message_modules_only(errors)
}

pub fn mixed_errors_is_false_test() {
  let errors = [
    gen_error.NoMessageModules(shared_path: "shared/src/shared"),
    gen_error.CannotReadDir(path: "shared/src/shared", cause: simplifile.Eacces),
  ]
  let assert False = gen.is_no_message_modules_only(errors)
}

pub fn multiple_no_message_modules_is_true_test() {
  let errors = list.repeat(gen_error.NoMessageModules(shared_path: "x"), 3)
  let assert True = gen.is_no_message_modules_only(errors)
}
