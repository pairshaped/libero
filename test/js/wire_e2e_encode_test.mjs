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
  ["echo_int", new messages.EchoInt(5), "{<<\"shared/types\">>,7,{echo_int,5}}"],
  ["echo_float", new messages.EchoFloat(3.5), "{<<\"shared/types\">>,7,{echo_float,3.5}}"],
  ["echo_string_utf8", new messages.EchoString("café"), "{<<\"shared/types\">>,7,{echo_string,<<\"caf"],
  ["echo_string_cjk", new messages.EchoString("漢字"), "{<<\"shared/types\">>,7,{echo_string,<<"],
  ["echo_bool", new messages.EchoBool(true), "{<<\"shared/types\">>,7,{echo_bool,true}}"],
  ["echo_bit_array", new messages.EchoBitArray(new gleam.BitArray(new Uint8Array([1, 2, 3]))), "{<<\"shared/types\">>,7,{echo_bit_array,<<1,2,3>>}}"],
  ["echo_unit", new messages.EchoUnit(), "{<<\"shared/types\">>,7,echo_unit}"],
  ["echo_list_int", new messages.EchoListInt(gleam.toList([1, 2, 3])), "{<<\"shared/types\">>,7,{echo_list_int,[1,2,3]}}"],
  ["echo_option_string", new messages.EchoOptionString(new option.Some("hello")), "{<<\"shared/types\">>,7,{echo_option_string,{some,<<\"hello\">>}}}"],
  ["echo_result_int_string", new messages.EchoResultIntString(new gleam.Error("bad")), "{<<\"shared/types\">>,7,{echo_result_int_string,{error,<<\"bad\">>}}}"],
  ["echo_dict_string_int", new messages.EchoDictStringInt(intDict), "{<<\"shared/types\">>,7,{echo_dict_string_int,#{<<\"one\">> => 1,<<\"two\">> => 2}}}"],
  ["echo_tuple_int_string", new messages.EchoTupleIntString([9, "nine"]), "{<<\"shared/types\">>,7,{echo_tuple_int_string,{9,<<\"nine\">>}}}"],
  ["echo_status", new messages.EchoStatus(new types.Active()), "{<<\"shared/types\">>,7,{echo_status,active}}"],
  ["echo_item", new messages.EchoItem(item), "{<<\"shared/types\">>,7,{echo_item,{item,7,<<\"wrench\">>,12.5,true}}}"],
  ["echo_tree", new messages.EchoTree(deepTree), "{<<\"shared/types\">>,7,{echo_tree,{node,1,{node,2,leaf,leaf},{node,3,leaf,{node,4,leaf,leaf}}}}}"],
  ["echo_item_error", new messages.EchoItemError(new types.ValidationFailed("name", "required")), "{<<\"shared/types\">>,7,{echo_item_error,{validation_failed,<<\"name\">>,<<\"required\">>}}}"],
  ["echo_with_floats", new messages.EchoWithFloats(new types.WithFloats(2.0, 3.0, "whole")), "{<<\"shared/types\">>,7,{echo_with_floats,{with_floats,2.0,3.0,<<\"whole\">>}}}"],
  ["echo_list_of_items", new messages.EchoListOfItems(gleam.toList([item, item2])), "{<<\"shared/types\">>,7,{echo_list_of_items,[{item,7,<<\"wrench\">>,12.5,true},{item,8,<<\"bolt\">>,1.25,false}]}}"],
  ["echo_option_item", new messages.EchoOptionItem(new option.Some(item)), "{<<\"shared/types\">>,7,{echo_option_item,{some,{item,7,<<\"wrench\">>,12.5,true}}}}"],
  ["echo_dict_string_item", new messages.EchoDictStringItem(itemDict), "{<<\"shared/types\">>,7,{echo_dict_string_item,#{<<\"one\">> => {item,7,<<\"wrench\">>,12.5,true},<<\"two\">> => {item,8,<<\"bolt\">>,1.25,false}}}}"],
  ["echo_nested_record", new messages.EchoNestedRecord(nested), "{<<\"shared/types\">>,7,{echo_nested_record,{nested_record,"],
  ["echo_typed_err", new messages.EchoTypedErr(item), "{<<\"shared/types\">>,7,{echo_typed_err,{item,7,<<\"wrench\">>,12.5,true}}}"],
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
    `Cases = [${erlangCases.join(",")}], lists:foreach(fun({Name, B64}) -> Term = binary_to_term(base64:decode(B64)), io:format("~s|~100000p~n", [Name, Term]) end, Cases), halt().`,
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
  assert.ok(terms.get(name).includes(expected), `${name}: ${terms.get(name)}`);
}

console.log(`wire e2e encode test passed (${cases.length} cases)`);
