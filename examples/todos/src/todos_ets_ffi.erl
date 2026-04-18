-module(todos_ets_ffi).
-export([init/0, insert/2, lookup/1, delete/1, all/0, next_id/0]).

init() ->
    case ets:whereis(todos) of
        undefined ->
            ets:new(todos, [named_table, public, set]),
            nil;
        _ ->
            ets:delete_all_objects(todos),
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
    [V || {_, V} <- ets:tab2list(todos)].

next_id() ->
    ets:info(todos, size) + 1.
