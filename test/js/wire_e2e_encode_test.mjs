import { strict as assert } from "node:assert";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const buildRoot = readFileSync("test/js/.wire_e2e_build_root", "utf8").trim();
const webRoot = join(buildRoot, "clients/web/build/dev/javascript");

await import(pathToFileURL(join(webRoot, "web/generated/rpc_decoders_ffi.mjs")).href);
const wire = await import(pathToFileURL(join(webRoot, "libero/libero/wire.mjs")).href);
const messages = await import(pathToFileURL(join(webRoot, "web/generated/messages.mjs")).href);
const types = await import(pathToFileURL(join(webRoot, "shared/shared/types.mjs")).href);
const gleam = await import(pathToFileURL(join(webRoot, "gleam_stdlib/gleam.mjs")).href);
const option = await import(
  pathToFileURL(join(webRoot, "gleam_stdlib/gleam/option.mjs")).href
);
const dict = await import(
  pathToFileURL(join(webRoot, "gleam_stdlib/gleam/dict.mjs")).href
);

const item = new types.Item(7, "wrench", 12.5, true);
const item2 = new types.Item(8, "bolt", 1.25, false);
const deepTree = new types.Node(
  1,
  new types.Node(2, new types.Leaf(), new types.Leaf()),
  new types.Node(3, new types.Leaf(), new types.Node(4, new types.Leaf(), new types.Leaf())),
);
const deepLeftTree = new types.Node(
  1,
  new types.Node(2,
    new types.Node(3, new types.Leaf(), new types.Leaf()),
    new types.Leaf()),
  new types.Leaf(),
);
const itemDict = dict.from_list(gleam.toList([
  ["one", item],
  ["two", item2],
]));
const intDict = dict.from_list(gleam.toList([
  ["one", 1],
  ["two", 2],
]));
const nested = new types.NestedRecord(
  gleam.toList([item, item2]),
  new option.Some(item),
  gleam.toList([new types.Pending(), new types.Active(), new types.Cancelled()]),
  itemDict,
);

const cases = [
  ["echo_int", new messages.EchoInt(5), "{echo_int,5}"],
  ["echo_int_zero", new messages.EchoInt(0), "{echo_int,0}"],
  ["echo_int_negative", new messages.EchoInt(-7), "{echo_int,-7}"],
  ["echo_float", new messages.EchoFloat(3.5), "{echo_float,3.5}"],
  ["echo_float_zero", new messages.EchoFloat(0.0), "{echo_float,0}"],
  ["echo_float_negative", new messages.EchoFloat(-1.5), "{echo_float,-1.5}"],
  ["echo_float_whole", new messages.EchoFloat(2.0), "{echo_float,2}"],
  ["echo_string_ascii", new messages.EchoString("hello"), "{echo_string,<<104,101,108,108,111>>}"],
  ["echo_string_empty", new messages.EchoString(""), "{echo_string,<<>>}"],
  ["echo_string_null_byte", new messages.EchoString("a\0b"), "{echo_string,<<97,0,98>>}"],
  ["echo_string_utf8", new messages.EchoString("caf\u00E9"), "{echo_string,<<99,97,102,195,169>>}"],
  ["echo_string_cjk", new messages.EchoString("\u6F22\u5B57"), "{echo_string,<<230,188,162,229,173,151>>}"],
  ["echo_bool", new messages.EchoBool(true), "{echo_bool,true}"],
  ["echo_bool_false", new messages.EchoBool(false), "{echo_bool,false}"],
  ["echo_bit_array", new messages.EchoBitArray(new gleam.BitArray(new Uint8Array([1, 2, 3]))), "{echo_bit_array,<<1,2,3>>}"],
  ["echo_bit_array_empty", new messages.EchoBitArray(new gleam.BitArray(new Uint8Array([]))), "{echo_bit_array,<<>>}"],
  ["echo_bit_array_single", new messages.EchoBitArray(new gleam.BitArray(new Uint8Array([255]))), "{echo_bit_array,<<255>>}"],
  ["echo_unit", new messages.EchoUnit(), "echo_unit"],
  ["echo_list_int", new messages.EchoListInt(gleam.toList([1, 2, 3])), "{echo_list_int,[1,2,3]}"],
  ["echo_list_int_empty", new messages.EchoListInt(gleam.toList([])), "{echo_list_int,[]}"],
  ["echo_list_int_single", new messages.EchoListInt(gleam.toList([42])), "{echo_list_int,[42]}"],
  ["echo_option_string", new messages.EchoOptionString(new option.Some("hello")), "{echo_option_string,{some,<<104,101,108,108,111>>}}"],
  ["echo_option_string_none", new messages.EchoOptionString(new option.None()), "{echo_option_string,none}"],
  ["echo_result_int_string", new messages.EchoResultIntString(new gleam.Error("bad")), "{echo_result_int_string,{error,<<98,97,100>>}}"],
  ["echo_result_int_string_ok", new messages.EchoResultIntString(new gleam.Ok(7)), "{echo_result_int_string,{ok,7}}"],
  ["echo_dict_string_int", new messages.EchoDictStringInt(intDict), "{echo_dict_string_int,#{<<111,110,101>> => 1,<<116,119,111>> => 2}}"],
  ["echo_dict_string_int_empty", new messages.EchoDictStringInt(dict.from_list(gleam.toList([]))), "{echo_dict_string_int,#{}}"],
  ["echo_tuple_int_string", new messages.EchoTupleIntString([9, "nine"]), "{echo_tuple_int_string,{9,<<110,105,110,101>>}}"],
  ["echo_status", new messages.EchoStatus(new types.Active()), "{echo_status,active}"],
  ["echo_status_pending", new messages.EchoStatus(new types.Pending()), "{echo_status,pending}"],
  ["echo_status_cancelled", new messages.EchoStatus(new types.Cancelled()), "{echo_status,cancelled}"],
  ["echo_item", new messages.EchoItem(item), "{echo_item,{item,7,<<119,114,101,110,99,104>>,12.5,true}}"],
  ["echo_tree", new messages.EchoTree(deepTree), "{echo_tree,{node,1,{node,2,leaf,leaf},{node,3,leaf,{node,4,leaf,leaf}}}}"],
  ["echo_tree_leaf", new messages.EchoTree(new types.Leaf()), "{echo_tree,leaf}"],
  ["echo_tree_deep_left", new messages.EchoTree(deepLeftTree), "{echo_tree,{node,1,{node,2,{node,3,leaf,leaf},leaf},leaf}}"],
  ["echo_item_error", new messages.EchoItemError(new types.ValidationFailed("name", "required")), "{echo_item_error,{validation_failed,<<110,97,109,101>>,<<114,101,113,117,105,114,101,100>>}}"],
  ["echo_item_error_not_found", new messages.EchoItemError(new types.NotFound()), "{echo_item_error,not_found}"],
  ["echo_with_floats", new messages.EchoWithFloats(new types.WithFloats(2.0, 3.0, "whole")), "{echo_with_floats,{with_floats,2.0,3.0,<<119,104,111,108,101>>}}"],
  ["echo_with_floats_zero", new messages.EchoWithFloats(new types.WithFloats(0.0, 0.0, "")), "{echo_with_floats,{with_floats,0.0,0.0,<<>>}}"],
  ["echo_list_of_items", new messages.EchoListOfItems(gleam.toList([item, item2])), "{echo_list_of_items,[{item,7,<<119,114,101,110,99,104>>,12.5,true},{item,8,<<98,111,108,116>>,1.25,false}]}"],
  ["echo_list_of_items_empty", new messages.EchoListOfItems(gleam.toList([])), "{echo_list_of_items,[]}"],
  ["echo_option_item", new messages.EchoOptionItem(new option.Some(item)), "{echo_option_item,{some,{item,7,<<119,114,101,110,99,104>>,12.5,true}}}"],
  ["echo_option_item_none", new messages.EchoOptionItem(new option.None()), "{echo_option_item,none}"],
  ["echo_dict_string_item", new messages.EchoDictStringItem(itemDict), "{echo_dict_string_item,#{<<111,110,101>> => {item,7,<<119,114,101,110,99,104>>,12.5,true},<<116,119,111>> => {item,8,<<98,111,108,116>>,1.25,false}}}"],
  ["echo_dict_string_item_empty", new messages.EchoDictStringItem(dict.from_list(gleam.toList([]))), "{echo_dict_string_item,#{}}"],
  ["echo_nested_record", new messages.EchoNestedRecord(nested), "{echo_nested_record,{nested_record,[{item,7,<<119,114,101,110,99,104>>,12.5,true},{item,8,<<98,111,108,116>>,1.25,false}],{some,{item,7,<<119,114,101,110,99,104>>,12.5,true}},[pending,active,cancelled],#{<<111,110,101>> => {item,7,<<119,114,101,110,99,104>>,12.5,true},<<116,119,111>> => {item,8,<<98,111,108,116>>,1.25,false}}}}"],
  ["echo_typed_err", new messages.EchoTypedErr(item), "{echo_typed_err,{item,7,<<119,114,101,110,99,104>>,12.5,true}}"],
];

const erlangCases = cases.map(([name, msg]) => {
  const payload = wire.encode_call("shared/types", 7, msg);
  return `{${JSON.stringify(name)},${JSON.stringify(Buffer.from(payload.rawBuffer).toString("base64"))}}`;
});
const printed = execFileSync(
  "erl",
  [
    "-noshell",
    "-eval",
    `Cases = [${erlangCases.join(",")}], lists:foreach(fun({Name, B64}) -> Term = binary_to_term(base64:decode(B64)), Msg = element(3, Term), io:format("~s|~w~n", [Name, Msg]) end, Cases), halt().`,
  ],
  { encoding: "utf8" },
);

const terms = new Map(
  printed.trim().split("\n").map((line) => {
    const [name, term] = line.split("|");
    return [name, term];
  }),
);

for (const [name, _msg, expected] of cases) {
  assert.equal(terms.get(name), expected, name);
}

console.log(`wire e2e encode test passed (${cases.length} cases)`);
