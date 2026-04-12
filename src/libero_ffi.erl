%% Libero RPC panic-catching FFI.
%%
%% try_call(F) runs the zero-arg function F and returns {ok, Result}
%% on success, or {error, ReasonBinary} if the function panics or
%% throws. The reason is stringified so the caller can log it
%% alongside a trace_id without pattern-matching on arbitrary
%% Erlang term shapes.

-module(libero_ffi).
-export([try_call/1, is_null/1]).

%% gleam_json decodes JSON null as the atom `null`. Gleam's Nil is `nil`.
%% This predicate lets wire.rebuild detect null values and convert them.
is_null(null) -> true;
is_null(_) -> false.

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
