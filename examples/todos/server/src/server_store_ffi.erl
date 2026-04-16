-module(server_store_ffi).
-export([create_table/0, next_id/0, put/2, get/1, all_rows/0, delete_row/1, int_compare/2]).

-define(TABLE, libero_todos).
-define(COUNTER, libero_todos_counter).

create_table() ->
    ets:new(?TABLE, [named_table, public, set, {keypos, 1}]),
    ets:new(?COUNTER, [named_table, public, set]),
    ets:insert(?COUNTER, {next_id, 0}),
    nil.

next_id() ->
    ets:update_counter(?COUNTER, next_id, 1).

put(Id, Todo) ->
    ets:insert(?TABLE, {Id, Todo}),
    nil.

get(Id) ->
    case ets:lookup(?TABLE, Id) of
        [{_, Todo}] -> {ok, Todo};
        [] -> {error, nil}
    end.

all_rows() ->
    Rows = ets:tab2list(?TABLE),
    lists:foldl(fun({_, Todo}, Acc) -> [Todo | Acc] end, [], Rows).

delete_row(Id) ->
    ets:delete(?TABLE, Id),
    nil.

int_compare(A, B) when A < B -> lt;
int_compare(A, B) when A > B -> gt;
int_compare(_, _) -> eq.
