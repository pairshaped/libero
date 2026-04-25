import { strict as assert } from "node:assert";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const buildRoot = readFileSync("test/js/.wire_e2e_build_root", "utf8").trim();
const webRoot = join(buildRoot, "clients/web/build/dev/javascript");
const manifest = JSON.parse(
  readFileSync("test/js/.wire_e2e_decode_manifest.json", "utf8"),
);

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

function decodeCase(name, decoder) {
  const bytes = Buffer.from(manifest[name], "base64");
  return decoder(rpcFfi.decode_value_raw(bytes));
}

function expectSuccess(data) {
  assert.ok(data instanceof remoteData.Success);
  return data[0];
}

function expectFailure(data) {
  assert.ok(data instanceof remoteData.Failure);
  return data[0];
}

function listToArray(list) {
  return Array.from(list);
}

function expectItem(item, expected) {
  assert.ok(item instanceof types.Item);
  assert.equal(item.id, expected.id);
  assert.equal(item.name, expected.name);
  assert.equal(item.price, expected.price);
  assert.equal(item.in_stock, expected.in_stock);
}

function expectValidationFailed(err) {
  assert.ok(err instanceof types.ValidationFailed);
  assert.equal(err.field, "name");
  assert.equal(err.reason, "required");
}

function dictGet(dictValue, key) {
  const result = dict.get(dictValue, key);
  assert.ok(result instanceof gleam.Ok);
  return result[0];
}

function expectDeepTree(tree) {
  assert.ok(tree instanceof types.Node);
  assert.equal(tree.value, 1);
  assert.ok(tree.left instanceof types.Node);
  assert.equal(tree.left.value, 2);
  assert.ok(tree.left.left instanceof types.Leaf);
  assert.ok(tree.left.right instanceof types.Leaf);
  assert.ok(tree.right instanceof types.Node);
  assert.equal(tree.right.value, 3);
  assert.ok(tree.right.right instanceof types.Node);
  assert.equal(tree.right.right.value, 4);
}

const item = { id: 7, name: "wrench", price: 12.5, in_stock: true };
const item2 = { id: 8, name: "bolt", price: 1.25, in_stock: false };

const cases = [
  ["echo_int/positive", decoders.decode_response_echo_int, (v) => assert.equal(v, 5)],
  ["echo_int/zero", decoders.decode_response_echo_int, (v) => assert.equal(v, 0)],
  ["echo_int/negative", decoders.decode_response_echo_int, (v) => assert.equal(v, -7)],
  ["echo_float/fractional", decoders.decode_response_echo_float, (v) => assert.equal(v, 3.5)],
  ["echo_float/negative", decoders.decode_response_echo_float, (v) => assert.equal(v, -1.5)],
  ["echo_float/whole", decoders.decode_response_echo_float, (v) => assert.equal(v, 2.0)],
  ["echo_string/ascii", decoders.decode_response_echo_string, (v) => assert.equal(v, "hello")],
  ["echo_string/empty", decoders.decode_response_echo_string, (v) => assert.equal(v, "")],
  ["echo_string/null_byte", decoders.decode_response_echo_string, (v) => assert.equal(v, "a\0b")],
  ["echo_string/utf8_cafe", decoders.decode_response_echo_string, (v) => assert.equal(v, "café")],
  ["echo_string/cjk", decoders.decode_response_echo_string, (v) => assert.equal(v, "漢字")],
  ["echo_bool/true", decoders.decode_response_echo_bool, (v) => assert.equal(v, true)],
  ["echo_bool/false", decoders.decode_response_echo_bool, (v) => assert.equal(v, false)],
  ["echo_bit_array/bytes", decoders.decode_response_echo_bit_array, (v) => assert.deepEqual([...v.rawBuffer], [1, 2, 3])],
  ["echo_bit_array/empty", decoders.decode_response_echo_bit_array, (v) => assert.deepEqual([...v.rawBuffer], [])],
  ["echo_bit_array/single", decoders.decode_response_echo_bit_array, (v) => assert.deepEqual([...v.rawBuffer], [255])],
  ["echo_unit/nil", decoders.decode_response_echo_unit, (v) => assert.equal(v, undefined)],
  ["echo_list_int/many", decoders.decode_response_echo_list_int, (v) => assert.deepEqual(listToArray(v), [1, 2, 3])],
  ["echo_list_int/empty", decoders.decode_response_echo_list_int, (v) => assert.deepEqual(listToArray(v), [])],
  ["echo_list_int/single", decoders.decode_response_echo_list_int, (v) => assert.deepEqual(listToArray(v), [42])],
  ["echo_option_string/some", decoders.decode_response_echo_option_string, (v) => {
    assert.ok(v instanceof option.Some);
    assert.equal(v[0], "hello");
  }],
  ["echo_option_string/none", decoders.decode_response_echo_option_string, (v) => assert.ok(v instanceof option.None)],
  ["echo_result_int_string/ok", decoders.decode_response_echo_result_int_string, (v) => {
    assert.ok(v instanceof gleam.Ok);
    assert.equal(v[0], 7);
  }],
  ["echo_result_int_string/error", decoders.decode_response_echo_result_int_string, (v) => {
    assert.ok(v instanceof gleam.Error);
    assert.equal(v[0], "bad");
  }],
  ["echo_dict_string_int/pairs", decoders.decode_response_echo_dict_string_int, (v) => {
    assert.equal(dictGet(v, "one"), 1);
    assert.equal(dictGet(v, "two"), 2);
  }],
  ["echo_dict_string_int/empty", decoders.decode_response_echo_dict_string_int, (v) => {
    assert.equal(dict.size(v), 0);
  }],
  ["echo_tuple_int_string/pair", decoders.decode_response_echo_tuple_int_string, (v) => assert.deepEqual(v, [9, "nine"])],
  ["echo_status/active", decoders.decode_response_echo_status, (v) => assert.ok(v instanceof types.Active)],
  ["echo_status/pending", decoders.decode_response_echo_status, (v) => assert.ok(v instanceof types.Pending)],
  ["echo_status/cancelled", decoders.decode_response_echo_status, (v) => assert.ok(v instanceof types.Cancelled)],
  ["echo_item/basic", decoders.decode_response_echo_item, (v) => expectItem(v, item)],
  ["echo_tree/leaf", decoders.decode_response_echo_tree, (v) => assert.ok(v instanceof types.Leaf)],
  ["echo_tree/deep", decoders.decode_response_echo_tree, expectDeepTree],
  ["echo_tree/deep_left", decoders.decode_response_echo_tree, (v) => {
    assert.ok(v instanceof types.Node);
    assert.equal(v.value, 1);
    assert.ok(v.left instanceof types.Node);
    assert.equal(v.left.value, 2);
    assert.ok(v.left.left instanceof types.Node);
    assert.equal(v.left.left.value, 3);
    assert.ok(v.left.right instanceof types.Leaf);
    assert.ok(v.right instanceof types.Leaf);
  }],
  ["echo_item_error/not_found", decoders.decode_response_echo_item_error, (v) => assert.ok(v instanceof types.NotFound)],
  ["echo_item_error/validation_failed", decoders.decode_response_echo_item_error, expectValidationFailed],
  ["echo_with_floats/whole", decoders.decode_response_echo_with_floats, (v) => {
    assert.ok(v instanceof types.WithFloats);
    assert.equal(v.x, 2.0);
    assert.equal(v.y, 3.0);
    assert.equal(v.label, "whole");
  }],
  ["echo_list_of_items/many", decoders.decode_response_echo_list_of_items, (v) => {
    const values = listToArray(v);
    assert.equal(values.length, 2);
    expectItem(values[0], item);
    expectItem(values[1], item2);
  }],
  ["echo_option_item/some", decoders.decode_response_echo_option_item, (v) => {
    assert.ok(v instanceof option.Some);
    expectItem(v[0], item);
  }],
  ["echo_option_item/none", decoders.decode_response_echo_option_item, (v) => assert.ok(v instanceof option.None)],
  ["echo_dict_string_item/pairs", decoders.decode_response_echo_dict_string_item, (v) => {
    expectItem(dictGet(v, "one"), item);
    expectItem(dictGet(v, "two"), item2);
  }],
  ["echo_dict_string_item/empty", decoders.decode_response_echo_dict_string_item, (v) => {
    assert.equal(dict.size(v), 0);
  }],
  ["echo_nested_record/basic", decoders.decode_response_echo_nested_record, (v) => {
    assert.ok(v instanceof types.NestedRecord);
    assert.equal(listToArray(v.items).length, 2);
    assert.ok(v.primary instanceof option.Some);
    expectItem(v.primary[0], item);
    const statuses = listToArray(v.statuses);
    assert.ok(statuses[0] instanceof types.Pending);
    assert.ok(statuses[1] instanceof types.Active);
    assert.ok(statuses[2] instanceof types.Cancelled);
    expectItem(dictGet(v.by_id, "one"), item);
  }],
];

for (const [name, decoder, assertValue] of cases) {
  assertValue(expectSuccess(decodeCase(name, decoder)));
}

expectValidationFailed(
  expectFailure(
    decodeCase(
      "echo_typed_err/validation_failed",
      decoders.decode_response_echo_typed_err,
    ),
  ),
);

console.log(`wire e2e decode test passed (${cases.length + 1} cases)`);
