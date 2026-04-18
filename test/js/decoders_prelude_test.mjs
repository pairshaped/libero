// Standalone unit tests for decoders_prelude.mjs.
//
// Run from the libero root:
//   node test/js/decoders_prelude_test.mjs
//
// No Gleam build required - the test mocks the stdlib setters directly.

import { strict as assert } from "assert";
import {
  DecodeError,
  decode_int,
  decode_float,
  decode_string,
  decode_bool,
  decode_bit_array,
  decode_list_of,
  decode_option_of,
  decode_result_of,
  decode_tuple_of,
  setOptionCtors,
  setResultCtors,
  setListCtors,
} from "../../src/libero/decoders_prelude.mjs";

// --- Minimal stubs for Gleam stdlib types ---

class Some {
  constructor(value) {
    this[0] = value;
  }
}
class None {}
class Ok {
  constructor(value) {
    this[0] = value;
  }
}
class ResultError {
  constructor(value) {
    this[0] = value;
  }
}
class Empty {}
class NonEmpty {
  constructor(head, tail) {
    this.head = head;
    this.tail = tail;
  }
}

setOptionCtors(Some, None);
setResultCtors(Ok, ResultError);
setListCtors(Empty, NonEmpty);

// --- Helpers ---

function assertThrows(fn, label) {
  try {
    fn();
  } catch (e) {
    if (e instanceof DecodeError) return;
    throw new Error(`${label}: expected DecodeError, got ${e.constructor.name}: ${e.message}`);
  }
  throw new Error(`${label}: expected throw, got nothing`);
}

// --- Tests ---

// decode_int
assert.strictEqual(decode_int(5), 5, "decode_int ok");
assert.strictEqual(decode_int(0), 0, "decode_int zero");
assert.strictEqual(decode_int(-3), -3, "decode_int negative");
assertThrows(() => decode_int("x"), "decode_int throws on string");
assertThrows(() => decode_int(null), "decode_int throws on null");

// decode_float
assert.strictEqual(decode_float(3.14), 3.14, "decode_float ok");
assertThrows(() => decode_float("3.14"), "decode_float throws on string");

// decode_string
assert.strictEqual(decode_string("foo"), "foo", "decode_string ok");
assert.strictEqual(decode_string(""), "", "decode_string empty");
assertThrows(() => decode_string(5), "decode_string throws on number");
assertThrows(() => decode_string(null), "decode_string throws on null");

// decode_bool
assert.strictEqual(decode_bool(true), true, "decode_bool true");
assert.strictEqual(decode_bool(false), false, "decode_bool false");
assert.strictEqual(decode_bool("true"), true, "decode_bool atom-true");
assert.strictEqual(decode_bool("false"), false, "decode_bool atom-false");
assertThrows(() => decode_bool("yes"), "decode_bool throws on unknown atom");
assertThrows(() => decode_bool(1), "decode_bool throws on number");

// decode_bit_array (pass-through)
const ba = new Uint8Array([1, 2, 3]);
assert.strictEqual(decode_bit_array(ba), ba, "decode_bit_array pass-through");

// decode_option_of
const opt_some = decode_option_of(decode_string, ["some", "x"]);
assert.ok(opt_some instanceof Some, "decode_option_of Some instance");
assert.strictEqual(opt_some[0], "x", "decode_option_of Some value");

const opt_none = decode_option_of(decode_string, "none");
assert.ok(opt_none instanceof None, "decode_option_of None instance");

assertThrows(
  () => decode_option_of(decode_string, "other"),
  "decode_option_of throws on unknown term",
);

// decode_result_of
const res_ok = decode_result_of(decode_string, decode_string, ["ok", "v"]);
assert.ok(res_ok instanceof Ok, "decode_result_of Ok instance");
assert.strictEqual(res_ok[0], "v", "decode_result_of Ok value");

const res_err = decode_result_of(decode_string, decode_string, ["error", "msg"]);
assert.ok(res_err instanceof ResultError, "decode_result_of Error instance");
assert.strictEqual(res_err[0], "msg", "decode_result_of Error value");

assertThrows(
  () => decode_result_of(decode_string, decode_string, ["unknown", "x"]),
  "decode_result_of throws on unknown tag",
);

// decode_list_of
const lst = decode_list_of(decode_int, [1, 2, 3]);
// Rebuild as array for assertion
const arr = [];
let cur = lst;
while (cur && cur.head !== undefined) {
  arr.push(cur.head);
  cur = cur.tail;
}
assert.deepStrictEqual(arr, [1, 2, 3], "decode_list_of values");

assertThrows(
  () => decode_list_of(decode_int, "not-a-list"),
  "decode_list_of throws on non-array",
);

// decode_list_of: element decoder is applied
assertThrows(
  () => decode_list_of(decode_int, ["a", "b"]),
  "decode_list_of propagates element decode error",
);

// decode_tuple_of
const tup = decode_tuple_of([decode_string, decode_int], ["hello", 42]);
assert.deepStrictEqual(tup, ["hello", 42], "decode_tuple_of values");

assertThrows(
  () => decode_tuple_of([decode_string, decode_int], ["hello"]),
  "decode_tuple_of throws on arity mismatch",
);

// DecodeError is instanceof Error
assert.ok(new DecodeError("test") instanceof Error, "DecodeError extends Error");
assert.strictEqual(new DecodeError("test").name, "DecodeError", "DecodeError name");

console.log("prelude tests passed");
