import { strict as assert } from "node:assert";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const buildRoot = readFileSync("test/js/.wire_e2e_build_root", "utf8").trim();
const webRoot = join(buildRoot, "clients/web/build/dev/javascript");
const manifest = JSON.parse(
  readFileSync("test/js/.wire_e2e_dispatch_manifest.json", "utf8"),
);
const textDecoder = new TextDecoder();

const rpcFfi = await import(
  pathToFileURL(join(webRoot, "libero/libero/rpc_ffi.mjs")).href
);
const decoders = await import(
  pathToFileURL(join(webRoot, "web/generated/rpc_decoders_ffi.mjs")).href
);
const remoteData = await import(
  pathToFileURL(join(webRoot, "libero/libero/remote_data.mjs")).href
);
const types = await import(
  pathToFileURL(join(webRoot, "shared/shared/types.mjs")).href
);
const gleam = await import(pathToFileURL(join(webRoot, "gleam_stdlib/gleam.mjs")).href);
const option = await import(
  pathToFileURL(join(webRoot, "gleam_stdlib/gleam/option.mjs")).href
);
const dict = await import(
  pathToFileURL(join(webRoot, "gleam_stdlib/gleam/dict.mjs")).href
);

function decodeFrame(base64) {
  const frame = Buffer.from(base64, "base64");
  assert.equal(frame[0], 0);
  const requestId = frame.readUInt32BE(1);
  const raw = rpcFfi.decode_value_raw(frame.subarray(5));
  return { requestId, raw };
}

function expectSuccess(frame, decoder) {
  const data = decoder(frame.raw);
  assert.ok(data instanceof remoteData.Success);
  return data[0];
}

function expectFailure(frame, decoder) {
  const data = decoder(frame.raw);
  assert.ok(data instanceof remoteData.Failure);
  return data[0];
}

function dictGet(dictValue, key) {
  const result = dict.get(dictValue, key);
  assert.ok(result instanceof gleam.Ok);
  return result[0];
}

function expectItem(item, expectedId) {
  assert.ok(item instanceof types.Item);
  assert.equal(item.id, expectedId);
}

function expectValidationFailed(err) {
  assert.ok(err instanceof types.ValidationFailed);
  assert.equal(err.field, "name");
  assert.equal(err.reason, "required");
}

function rawBinaryToString(value) {
  assert.equal(value.__liberoRawBinary, true);
  return textDecoder.decode(value.rawBuffer);
}

const expectedRequestIds = {
  "echo_int/positive": 41,
  "echo_int_negated/positive": 42,
  "echo_float/fractional": 43,
  "echo_string/utf8_cafe": 44,
  "echo_string/cjk": 45,
  "echo_bool/true": 46,
  "echo_bit_array/bytes": 47,
  "echo_unit/nil": 48,
  "echo_list_int/many": 49,
  "echo_option_string/some": 50,
  "echo_result_int_string/error": 51,
  "echo_dict_string_int/pairs": 52,
  "echo_tuple_int_string/pair": 53,
  "echo_status/active": 54,
  "echo_item/basic": 55,
  "echo_tree/deep": 56,
  "echo_item_error/validation_failed": 57,
  "echo_with_floats/whole": 58,
  "echo_list_of_items/many": 59,
  "echo_option_item/some": 60,
  "echo_dict_string_item/pairs": 61,
  "echo_nested_record/basic": 62,
  "echo_typed_err/validation_failed": 63,
  "dispatch/handler_panic": 65,
  "dispatch/unknown_variant": 66,
};

for (const [name, requestId] of Object.entries(expectedRequestIds)) {
  assert.equal(decodeFrame(manifest[name]).requestId, requestId, name);
}

assert.equal(
  expectSuccess(decodeFrame(manifest["echo_int/positive"]), decoders.decode_response_echo_int),
  5,
);
assert.equal(
  expectSuccess(
    decodeFrame(manifest["echo_int_negated/positive"]),
    decoders.decode_response_echo_int_negated,
  ),
  -5,
);
assert.equal(
  expectSuccess(
    decodeFrame(manifest["echo_string/utf8_cafe"]),
    decoders.decode_response_echo_string,
  ),
  "café",
);
assert.equal(
  expectSuccess(decodeFrame(manifest["echo_string/cjk"]), decoders.decode_response_echo_string),
  "漢字",
);
assert.deepEqual(
  [...expectSuccess(
    decodeFrame(manifest["echo_bit_array/bytes"]),
    decoders.decode_response_echo_bit_array,
  ).rawBuffer],
  [1, 2, 3],
);
assert.deepEqual(
  Array.from(
    expectSuccess(decodeFrame(manifest["echo_list_int/many"]), decoders.decode_response_echo_list_int),
  ),
  [1, 2, 3],
);
const resultValue = expectSuccess(
  decodeFrame(manifest["echo_result_int_string/error"]),
  decoders.decode_response_echo_result_int_string,
);
assert.ok(resultValue instanceof gleam.Error);
assert.equal(resultValue[0], "bad");

const dictInts = expectSuccess(
  decodeFrame(manifest["echo_dict_string_int/pairs"]),
  decoders.decode_response_echo_dict_string_int,
);
assert.equal(dictGet(dictInts, "one"), 1);
assert.equal(dictGet(dictInts, "two"), 2);

assert.ok(
  expectSuccess(decodeFrame(manifest["echo_status/active"]), decoders.decode_response_echo_status)
    instanceof types.Active,
);
expectItem(
  expectSuccess(decodeFrame(manifest["echo_item/basic"]), decoders.decode_response_echo_item),
  7,
);
assert.ok(
  expectSuccess(decodeFrame(manifest["echo_tree/deep"]), decoders.decode_response_echo_tree)
    instanceof types.Node,
);
expectValidationFailed(
  expectSuccess(
    decodeFrame(manifest["echo_item_error/validation_failed"]),
    decoders.decode_response_echo_item_error,
  ),
);

const optionItem = expectSuccess(
  decodeFrame(manifest["echo_option_item/some"]),
  decoders.decode_response_echo_option_item,
);
assert.ok(optionItem instanceof option.Some);
expectItem(optionItem[0], 7);

const dictItems = expectSuccess(
  decodeFrame(manifest["echo_dict_string_item/pairs"]),
  decoders.decode_response_echo_dict_string_item,
);
expectItem(dictGet(dictItems, "one"), 7);
expectItem(dictGet(dictItems, "two"), 8);

const nested = expectSuccess(
  decodeFrame(manifest["echo_nested_record/basic"]),
  decoders.decode_response_echo_nested_record,
);
assert.ok(nested instanceof types.NestedRecord);
expectItem(dictGet(nested.by_id, "one"), 7);

expectValidationFailed(
  expectFailure(
    decodeFrame(manifest["echo_typed_err/validation_failed"]),
    decoders.decode_response_echo_typed_err,
  ),
);

const unknown = decodeFrame(manifest["dispatch/unknown_module"]);
assert.equal(unknown.requestId, 64);
assert.equal(unknown.raw[0], "error");
assert.equal(unknown.raw[1][0], "unknown_function");
assert.equal(rawBinaryToString(unknown.raw[1][1]), "other/module");

const malformed = decodeFrame(manifest["dispatch/malformed_envelope"]);
assert.equal(malformed.requestId, 0);
assert.equal(malformed.raw[0], "error");
assert.equal(malformed.raw[1], "malformed_request");

const panic = decodeFrame(manifest["dispatch/handler_panic"]);
assert.equal(panic.requestId, 65);
assert.equal(panic.raw[0], "error");
assert.equal(panic.raw[1][0], "internal_error");
assert.ok(rawBinaryToString(panic.raw[1][1]).length > 0, "trace_id should be a non-empty binary");
assert.equal(rawBinaryToString(panic.raw[1][2]), "Internal server error");

// Known module path with an unrecognized variant atom must surface as
// unknown_function with the qualified name, not crash dispatch.
const unknownVariant = decodeFrame(manifest["dispatch/unknown_variant"]);
assert.equal(unknownVariant.requestId, 66);
assert.equal(unknownVariant.raw[0], "error");
assert.equal(unknownVariant.raw[1][0], "unknown_function");
assert.equal(
  rawBinaryToString(unknownVariant.raw[1][1]),
  "shared/types.bogus_function",
);

console.log(`wire e2e dispatch test passed (${Object.keys(manifest).length} cases)`);
