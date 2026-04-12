-module(libero_wire_ffi).
-export([decode_call/1]).

%% Decode an ETF binary, validate it's a {Binary, List} call envelope,
%% and return a Gleam-shaped Result: {ok, {Name, Args}} or
%% {error, {decode_error, Message}}.
%%
%% Note: binary_to_term/2 is called with [safe] to prevent atom
%% exhaustion attacks. All legitimate constructor atoms are pre-
%% registered by the generated rpc_atoms module (ensure/0) before
%% the first RPC arrives.
decode_call(Bin) when is_binary(Bin) ->
    try erlang:binary_to_term(Bin, [safe]) of
        {Name, Args} when is_binary(Name), is_list(Args) ->
            {ok, {Name, Args}};
        _ ->
            {error, {decode_error, <<"invalid call envelope: expected {binary, list}">>}}
    catch
        _:_ ->
            {error, {decode_error, <<"invalid ETF binary">>}}
    end;
decode_call(_) ->
    {error, {decode_error, <<"expected a binary (BitArray)">>}}.
