// FFI for libero/remote_data.gleam - JavaScript target only.
//
// MsgFromServer variants compile to Gleam CustomType subclasses where
// the single payload field is stored at numeric index 0 (i.e. `instance[0]`).
// This matches the compiled output: `constructor($0) { this[0] = $0; }`.
//
// For 0-arity variants (no fields), the wrapper itself IS the value;
// return undefined (Gleam Nil) as an empty acknowledgment.

export function peelMsgWrapper(wrapper) {
  if (wrapper === null || wrapper === undefined) return undefined;
  // Numeric index 0 is the first field of any Gleam custom type variant
  // with fields. If the variant has no fields, wrapper[0] is undefined,
  // which is Gleam Nil - correct for 0-arity acknowledgment variants.
  return wrapper[0];
}
