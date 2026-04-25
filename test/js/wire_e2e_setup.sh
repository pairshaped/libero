#!/usr/bin/env sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
FIXTURE_SRC="$ROOT_DIR/test/fixtures/wire_e2e"
STAGE_ROOT="${TMPDIR:-/tmp}/libero-wire-e2e"
STAGED_FIXTURE="$STAGE_ROOT/wire_e2e"
BUILD_ROOT_FILE="$ROOT_DIR/test/js/.wire_e2e_build_root"
DECODE_MANIFEST="$ROOT_DIR/test/js/.wire_e2e_decode_manifest.json"
DISPATCH_MANIFEST="$ROOT_DIR/test/js/.wire_e2e_dispatch_manifest.json"

if [ "${1:-}" = "--clean" ]; then
  rm -rf "$STAGE_ROOT"
  rm -f "$BUILD_ROOT_FILE" "$DECODE_MANIFEST" "$DISPATCH_MANIFEST"
fi

rm -rf "$STAGED_FIXTURE"
mkdir -p "$STAGED_FIXTURE"

cp "$FIXTURE_SRC/gleam.toml" "$STAGED_FIXTURE/gleam.toml"
mkdir -p "$STAGED_FIXTURE/shared/src" "$STAGED_FIXTURE/src" "$STAGED_FIXTURE/clients"
cp -R "$FIXTURE_SRC/shared/." "$STAGED_FIXTURE/shared/"
cp -R "$FIXTURE_SRC/shared_src/." "$STAGED_FIXTURE/shared/src/"
cp -R "$FIXTURE_SRC/server_src/." "$STAGED_FIXTURE/src/"
mkdir -p "$STAGED_FIXTURE/clients/web"
cp -R "$FIXTURE_SRC/clients/web/." "$STAGED_FIXTURE/clients/web/"
mkdir -p "$STAGED_FIXTURE/clients/web/src"
cp -R "$FIXTURE_SRC/client_src/." "$STAGED_FIXTURE/clients/web/src/"

find "$STAGED_FIXTURE" -name '*.gleam.template' -exec sh -c '
  for path do
    mv "$path" "${path%.template}"
  done
' sh {} +

perl -0pi -e "s#libero = \\{ path = \"[^\"]+\" \\}#libero = { path = \"$ROOT_DIR\" }#g" \
  "$STAGED_FIXTURE/gleam.toml"
perl -0pi -e "s#libero = \\{ path = \"[^\"]+\" \\}#libero = { path = \"$ROOT_DIR\" }#g" \
  "$STAGED_FIXTURE/clients/web/gleam.toml"

(
  cd "$STAGED_FIXTURE"
  gleam run -m libero -- gen
  gleam build --target erlang
)

(
  cd "$STAGED_FIXTURE/clients/web"
  gleam build --target javascript
)

printf '%s\n' "$STAGED_FIXTURE" > "$BUILD_ROOT_FILE"

erl -noshell -eval '
Encode = fun(Term) -> binary_to_list(base64:encode(erlang:term_to_binary(Term))) end,
Item = {item, 7, <<"wrench">>, 12.5, true},
Item2 = {item, 8, <<"bolt">>, 1.25, false},
DeepTree = {node, 1, {node, 2, leaf, leaf}, {node, 3, leaf, {node, 4, leaf, leaf}}},
Nested = {nested_record, [Item, Item2], {some, Item}, [pending, active, cancelled], #{<<"one">> => Item, <<"two">> => Item2}},
Cases = [
  {"echo_int/positive", {ok, {ok, 5}}},
  {"echo_float/fractional", {ok, {ok, 3.5}}},
  {"echo_string/ascii", {ok, {ok, <<"hello">>}}},
  {"echo_string/utf8_cafe", {ok, {ok, <<"caf", 195, 169>>}}},
  {"echo_string/cjk", {ok, {ok, unicode:characters_to_binary([28450, 23383])}}},
  {"echo_bool/true", {ok, {ok, true}}},
  {"echo_bool/false", {ok, {ok, false}}},
  {"echo_bit_array/bytes", {ok, {ok, <<1, 2, 3>>}}},
  {"echo_unit/nil", {ok, {ok, nil}}},
  {"echo_list_int/many", {ok, {ok, [1, 2, 3]}}},
  {"echo_option_string/some", {ok, {ok, {some, <<"hello">>}}}},
  {"echo_option_string/none", {ok, {ok, none}}},
  {"echo_result_int_string/ok", {ok, {ok, {ok, 7}}}},
  {"echo_result_int_string/error", {ok, {ok, {error, <<"bad">>}}}},
  {"echo_dict_string_int/pairs", {ok, {ok, #{<<"one">> => 1, <<"two">> => 2}}}},
  {"echo_tuple_int_string/pair", {ok, {ok, {9, <<"nine">>}}}},
  {"echo_status/active", {ok, {ok, active}}},
  {"echo_item/basic", {ok, {ok, Item}}},
  {"echo_tree/leaf", {ok, {ok, leaf}}},
  {"echo_tree/deep", {ok, {ok, DeepTree}}},
  {"echo_item_error/not_found", {ok, {ok, not_found}}},
  {"echo_item_error/validation_failed", {ok, {ok, {validation_failed, <<"name">>, <<"required">>}}}},
  {"echo_with_floats/whole", {ok, {ok, {with_floats, 2.0, 3.0, <<"whole">>}}}},
  {"echo_list_of_items/many", {ok, {ok, [Item, Item2]}}},
  {"echo_option_item/some", {ok, {ok, {some, Item}}}},
  {"echo_option_item/none", {ok, {ok, none}}},
  {"echo_dict_string_item/pairs", {ok, {ok, #{<<"one">> => Item, <<"two">> => Item2}}}},
  {"echo_nested_record/basic", {ok, {ok, Nested}}},
  {"echo_typed_err/validation_failed", {ok, {error, {validation_failed, <<"name">>, <<"required">>}}}}
],
Print = fun
  Print([], _) -> ok;
  Print([{Name, Term}], Prefix) ->
    io:format("~s\"~s\": \"~s\"~n", [Prefix, Name, Encode(Term)]);
  Print([{Name, Term} | Rest], Prefix) ->
    io:format("~s\"~s\": \"~s\",~n", [Prefix, Name, Encode(Term)]),
    Print(Rest, Prefix)
end,
io:format("{~n"),
Print(Cases, "  "),
io:format("}~n"),
halt().
' > "$DECODE_MANIFEST"

ERL_EBINS=$(find "$STAGED_FIXTURE/build/dev/erlang" -path '*/ebin' -type d | tr '\n' ' ')
erl -noshell -pa $ERL_EBINS -eval '
EncodeCall = fun(RequestId, Msg) ->
  libero_ffi:encode({<<"shared/types">>, RequestId, Msg})
end,
EncodeFrame = fun(Frame) -> binary_to_list(base64:encode(Frame)) end,
State0 = server@handler_context:new(),
Item = {item, 7, <<"wrench">>, 12.5, true},
Item2 = {item, 8, <<"bolt">>, 1.25, false},
DeepTree = {node, 1, {node, 2, leaf, leaf}, {node, 3, leaf, {node, 4, leaf, leaf}}},
Nested = {nested_record, [Item, Item2], {some, Item}, [pending, active, cancelled], #{<<"one">> => Item, <<"two">> => Item2}},
Cases = [
  {"echo_int/positive", 41, {echo_int, 5}},
  {"echo_int_negated/positive", 42, {echo_int_negated, 5}},
  {"echo_float/fractional", 43, {echo_float, 3.5}},
  {"echo_string/utf8_cafe", 44, {echo_string, <<"caf", 195, 169>>}},
  {"echo_string/cjk", 45, {echo_string, unicode:characters_to_binary([28450, 23383])}},
  {"echo_bool/true", 46, {echo_bool, true}},
  {"echo_bit_array/bytes", 47, {echo_bit_array, <<1, 2, 3>>}},
  {"echo_unit/nil", 48, echo_unit},
  {"echo_list_int/many", 49, {echo_list_int, [1, 2, 3]}},
  {"echo_option_string/some", 50, {echo_option_string, {some, <<"hello">>}}},
  {"echo_result_int_string/error", 51, {echo_result_int_string, {error, <<"bad">>}}},
  {"echo_dict_string_int/pairs", 52, {echo_dict_string_int, #{<<"one">> => 1, <<"two">> => 2}}},
  {"echo_tuple_int_string/pair", 53, {echo_tuple_int_string, {9, <<"nine">>}}},
  {"echo_status/active", 54, {echo_status, active}},
  {"echo_item/basic", 55, {echo_item, Item}},
  {"echo_tree/deep", 56, {echo_tree, DeepTree}},
  {"echo_item_error/validation_failed", 57, {echo_item_error, {validation_failed, <<"name">>, <<"required">>}}},
  {"echo_with_floats/whole", 58, {echo_with_floats, {with_floats, 2.0, 3.0, <<"whole">>}}},
  {"echo_list_of_items/many", 59, {echo_list_of_items, [Item, Item2]}},
  {"echo_option_item/some", 60, {echo_option_item, {some, Item}}},
  {"echo_dict_string_item/pairs", 61, {echo_dict_string_item, #{<<"one">> => Item, <<"two">> => Item2}}},
  {"echo_nested_record/basic", 62, {echo_nested_record, Nested}},
  {"echo_typed_err/validation_failed", 63, {echo_typed_err, Item}},
  {"dispatch/unknown_module", 64, {<<"other/module">>, 64, {echo_int, 5}}},
  {"dispatch/malformed_envelope", 0, malformed}
],
Run = fun
  ({"dispatch/unknown_module", _Id, Envelope}, State) ->
    server@generated@dispatch:handle(State, libero_ffi:encode(Envelope));
  ({"dispatch/malformed_envelope", _Id, malformed}, State) ->
    server@generated@dispatch:handle(State, <<131, 104, 1, 97, 1>>);
  ({_Name, Id, Msg}, State) ->
    server@generated@dispatch:handle(State, EncodeCall(Id, Msg))
end,
{Entries, _StateN} = lists:foldl(fun(Case, {Acc, State}) ->
  {Name, _Id, _Msg} = Case,
  {Resp, _Panic, NewState} = Run(Case, State),
  {[{Name, Resp} | Acc], NewState}
end, {[], State0}, Cases),
Print = fun
  Print([], _) -> ok;
  Print([{Name, Frame}], Prefix) ->
    io:format("~s\"~s\": \"~s\"~n", [Prefix, Name, EncodeFrame(Frame)]);
  Print([{Name, Frame} | Rest], Prefix) ->
    io:format("~s\"~s\": \"~s\",~n", [Prefix, Name, EncodeFrame(Frame)]),
    Print(Rest, Prefix)
end,
io:format("{~n"),
Print(lists:reverse(Entries), "  "),
io:format("}~n"),
halt().
' > "$DISPATCH_MANIFEST"
