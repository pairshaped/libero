%% Libero RPC panic-catching FFI.
%%
%% try_call(F) runs the zero-arg function F and returns {ok, Result}
%% on success, or {error, ReasonBinary} if the function panics or
%% throws. The reason is stringified so the caller can log it
%% alongside a trace_id without pattern-matching on arbitrary
%% Erlang term shapes.

-module(libero_ffi).
-export([try_call/1, encode/1, decode/1, decode_safe/1, identity/1, trap_signals/0, peel_msg_wrapper/1]).

identity(X) -> X.

encode(Term) ->
    erlang:term_to_binary(Term).

decode(Bin) ->
    erlang:binary_to_term(Bin, [safe]).

decode_safe(Bin) ->
    try erlang:binary_to_term(Bin, [safe]) of
        Term -> {ok, Term}
    catch
        _:Reason ->
            Msg = erlang:iolist_to_binary(
                io_lib:format("~p", [Reason])
            ),
            {error, {decode_error, Msg}}
    end.

%% Install signal handlers so libero exits cleanly when its parent
%% build script is killed (Ctrl-C, SIGTERM from sandbox, etc.).
%% Without this, a stuck or in-progress libero process can survive
%% its parent and spin at 99% CPU.
trap_signals() ->
    os:set_signal(sigterm, handle),
    os:set_signal(sighup, handle),
    spawn(fun signal_loop/0),
    nil.

signal_loop() ->
    receive
        {signal, sigterm} -> erlang:halt(1);
        {signal, sighup}  -> erlang:halt(1);
        _Other            -> signal_loop()
    end.

%% Extract the single payload field from a MsgFromServer variant.
%%
%% In Erlang, Gleam custom type variants compile to tuples of the form
%% `{atom, Field1, ...}`. Every MsgFromServer variant carries exactly one
%% field (the response payload), so `element(2, Tuple)` extracts it.
%% 0-arity variants compile to bare atoms and carry no payload; for those
%% we return nil (Gleam Nil) as a typed empty acknowledgment.
%%
%% The codegen validates that MsgFromServer variants have at most 1 field
%% (scanner.validate_msg_from_server_fields), so tuple_size == 2 is the
%% expected case. The >= 2 guard + element(2) is intentional — if a
%% variant somehow has extra fields, we still extract the first one
%% rather than crashing, since the codegen is the enforcement point.
peel_msg_wrapper(Tuple) when is_tuple(Tuple), tuple_size(Tuple) >= 2 ->
    element(2, Tuple);
peel_msg_wrapper(Atom) when is_atom(Atom) ->
    nil;
peel_msg_wrapper(Other) ->
    Other.

try_call(F) ->
    try F() of
        Result -> {ok, Result}
    catch
        Class:Reason:Stacktrace ->
            Message = io_lib:format(
                "~p: ~p~nstacktrace: ~p",
                [Class, Reason, Stacktrace]
            ),
            {error, erlang:iolist_to_binary(Message)}
    end.
