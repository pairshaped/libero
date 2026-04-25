// FFI for libero/remote_data.gleam - JavaScript target only.
//
// MsgFromServer variants compile to Gleam CustomType subclasses where
// the single payload field is stored at numeric index 0 (i.e. `instance[0]`).
// This matches the compiled output: `constructor($0) { this[0] = $0; }`.
//
// 0-arity variants compile to no-field instances; we return undefined
// (Gleam Nil) as a typed empty acknowledgment.

export function peelMsgWrapper(wrapper) {
  // A primitive (number, string, bool) or a plain object/array means the
  // wire payload isn't a Gleam variant instance. Codegen produces only
  // variant shapes here, so anything else is a programming error. Throw
  // loud and traceable instead of returning garbage that wire.coerce
  // would cast into a typed value downstream.
  if (
    wrapper === null
    || wrapper === undefined
    || typeof wrapper !== "object"
    || Array.isArray(wrapper)
  ) {
    throw new Error(
      `peel_msg_wrapper_unexpected_shape: ${JSON.stringify(wrapper)}`,
    );
  }
  return wrapper[0];
}
