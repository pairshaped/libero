-module(counter_ets_ffi).
-export([init/0, get/0, increment/0, decrement/0]).

init() ->
    case ets:whereis(counter) of
        undefined ->
            ets:new(counter, [named_table, public, set]),
            ets:insert(counter, {value, 0}),
            nil;
        _ ->
            ets:delete_all_objects(counter),
            ets:insert(counter, {value, 0}),
            nil
    end.

get() ->
    case ets:lookup(counter, value) of
        [{value, V}] -> V;
        [] -> 0
    end.

increment() ->
    ets:update_counter(counter, value, 1).

decrement() ->
    ets:update_counter(counter, value, -1).
