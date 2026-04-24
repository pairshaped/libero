-module(libero_wire_ffi).
-export([decode_call/1]).

%% Decode an ETF binary, validate it's a {Binary, Integer, Value} call envelope,
%% and return a Gleam-shaped Result: {ok, {Name, RequestId, Value}} or
%% {error, {decode_error, Message}}.
%%
%% The wire envelope is {module_name_binary, request_id, msg_from_client_value} -
%% a 3-tuple where the first element is a UTF-8 binary naming the shared module,
%% the second is an integer request ID, and the third is the typed MsgFromClient
%% value. The request ID lets the client correlate responses to calls.
%%
%% Note: binary_to_term/2 is called with [safe] to prevent atom
%% exhaustion attacks. All legitimate constructor atoms are pre-
%% registered by the generated rpc_atoms module (ensure/0) before
%% the first RPC arrives.
decode_call(Bin) when is_binary(Bin) ->
    try erlang:binary_to_term(Bin, [safe]) of
        {Module, RequestId, Value} when is_binary(Module), is_integer(RequestId) ->
            {ok, {Module, RequestId, Value}};
        _ ->
            {error, {decode_error, <<"invalid call envelope: expected {binary, integer, value} tuple">>}}
    catch
        _:_ ->
            {error, {decode_error, <<"invalid ETF binary">>}}
    end;
decode_call(_) ->
    {error, {decode_error, <<"expected a binary (BitArray)">>}}.
