%% Generates the base64-encoded dispatch manifest consumed by
%% wire_e2e_dispatch_test.mjs. Each entry maps a case name to the
%% base64-encoded response frame produced by server@generated@dispatch:handle/2.
%%
%% Expects the fixture ebin directory as an -extra argument.
%% Called from wire_e2e_setup.sh:
%%   erl -noshell -pa <ebin_dirs> -eval "$(cat dispatch_manifest.erl)" > manifest.json

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
  {"dispatch/malformed_envelope", 0, malformed},
  {"dispatch/handler_panic", 65, {echo_panic, 0}}
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
