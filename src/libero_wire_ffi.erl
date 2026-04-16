-module(libero_wire_ffi).
-export([decode_call/1]).

%% Decode an ETF binary, validate it's a {Binary, Value} call envelope,
%% and return a Gleam-shaped Result: {ok, {Name, Value}} or
%% {error, {decode_error, Message}}.
%%
%% The wire envelope is {module_name_binary, msg_from_client_value} - a 2-tuple
%% where the second element is a single value (not a list). This allows
%% the dispatch to coerce the value directly to the typed MsgFromClient message.
%%
%% Note: binary_to_term/2 is called with [safe] to prevent atom
%% exhaustion attacks. All legitimate constructor atoms are pre-
%% registered by the generated rpc_atoms module (ensure/0) before
%% the first RPC arrives.
decode_call(Bin) when is_binary(Bin) ->
    try erlang:binary_to_term(Bin, [safe]) of
        {Module, Value} when is_binary(Module) ->
            {ok, {Module, Value}};
        _ ->
            {error, {decode_error, <<"invalid call envelope: expected {binary, value} tuple">>}}
    catch
        _:_ ->
            {error, {decode_error, <<"invalid ETF binary">>}}
    end;
decode_call(_) ->
    {error, {decode_error, <<"expected a binary (BitArray)">>}}.
