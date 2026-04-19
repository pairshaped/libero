-module(todos_ets_ffi).
-export([init/0, insert/2, lookup/1, delete/1, all/0, next_id/0]).

-define(COUNTER_KEY, '$next_id').

init() ->
    case ets:whereis(todos) of
        undefined ->
            ets:new(todos, [named_table, public, set]),
            ets:insert(todos, {?COUNTER_KEY, 0}),
            nil;
        _ ->
            ets:delete_all_objects(todos),
            ets:insert(todos, {?COUNTER_KEY, 0}),
            nil
    end.

insert(Id, Record) ->
    ets:insert(todos, {Id, Record}),
    nil.

lookup(Id) ->
    case ets:lookup(todos, Id) of
        [{_, V}] -> {ok, V};
        [] -> {error, nil}
    end.

delete(Id) ->
    ets:delete(todos, Id),
    nil.

all() ->
    [V || {K, V} <- ets:tab2list(todos), K =/= ?COUNTER_KEY].

%% Monotonically increasing counter — safe after deletions.
next_id() ->
    ets:update_counter(todos, ?COUNTER_KEY, 1).
