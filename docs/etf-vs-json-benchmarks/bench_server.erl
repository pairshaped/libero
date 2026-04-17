%% Server-side (BEAM) benchmark: ETF vs JSON encode/decode.
%%
%% Usage:
%%   cd <project>/server
%%   erlc ../lib/libero/benchmarks/bench_server.erl
%%   erl -pa build/dev/erlang/*/ebin -noshell -eval 'bench_server:run(), halt().'
%%   rm bench_server.beam

-module(bench_server).
-export([run/0]).

run() ->
    %% Realistic admin RPC response: 5 discounts with ~20 fields each,
    %% plus item options, question options, and a dict of question values.
    D = {discount, 1, 1, <<"Early Bird">>, {some, <<"Inscription native">>},
         10.0, 0, true, false, false, false, [], none, none, none,
         none, none, false, none, none, none, 1712000000, 1712000000},
    Discounts = [D, D, D, D, D],
    Response = {ok, {admin_data, Discounts, Discounts,
      [{item_option, 1, <<"League A">>}, {item_option, 2, <<"League B">>},
       {item_option, 3, <<"Tournament C">>}, {item_option, 4, <<"Camp D">>}],
      [{question_option, <<"gender">>, <<"Gender">>, <<"select">>},
       {question_option, <<"age">>, <<"Age">>, <<"number">>}],
      #{<<"gender">> => [{<<"male">>, <<"Male">>}, {<<"female">>, <<"Female">>},
                         {<<"unspecified">>, <<"Unspecified">>}]}
    }},

    J = 'gleam@json',

    %% Walk function: mirrors libero's wire.gleam JSON encoder.
    %% Converts any Erlang term to a gleam_json Json tree.
    Walk = fun Walk(Term) ->
      if
        is_boolean(Term) -> J:bool(Term);
        Term =:= nil -> J:null();
        is_atom(Term) ->
          Name = atom_to_binary(Term),
          J:object([{<<"@">>, J:string(Name)}, {<<"v">>, J:preprocessed_array([])}]);
        is_integer(Term) -> J:int(Term);
        is_float(Term) -> J:float(Term);
        is_binary(Term) -> J:string(Term);
        is_list(Term) -> J:preprocessed_array([Walk(E) || E <- Term]);
        is_map(Term) ->
          Pairs = [J:preprocessed_array([Walk(K), Walk(V)]) || {K, V} <- maps:to_list(Term)],
          J:object([{<<"@">>, J:string(<<"dict">>)}, {<<"v">>, J:preprocessed_array(Pairs)}]);
        is_tuple(Term) ->
          [First | Rest] = tuple_to_list(Term),
          case is_atom(First) andalso not is_boolean(First) of
            true ->
              Name = atom_to_binary(First),
              J:object([{<<"@">>, J:string(Name)},
                        {<<"v">>, J:preprocessed_array([Walk(E) || E <- Rest])}]);
            false ->
              J:preprocessed_array([Walk(E) || E <- tuple_to_list(Term)])
          end
      end
    end,

    N = 100000,
    Warmup = 10000,

    %% --- Warmup ---
    lists:foreach(fun(_) ->
      erlang:term_to_binary(Response),
      erlang:binary_to_term(erlang:term_to_binary(Response)),
      J:to_string(Walk(Response)),
      rebuild_term(json:decode(iolist_to_binary(J:to_string(Walk(Response)))))
    end, lists:seq(1, Warmup)),

    %% --- JSON encode (walk + to_string) ---
    {JsonEncTime, _} = timer:tc(fun() ->
      lists:foreach(fun(_) ->
        Tree = Walk(Response),
        J:to_string(Tree)
      end, lists:seq(1, N))
    end),
    JsonBin = iolist_to_binary(J:to_string(Walk(Response))),

    %% --- JSON decode + rebuild (parse then reconstruct Erlang terms) ---
    {JsonDecTime, _} = timer:tc(fun() ->
      lists:foreach(fun(_) ->
        rebuild_term(json:decode(JsonBin))
      end, lists:seq(1, N))
    end),

    %% --- ETF encode ---
    {ETFEncTime, _} = timer:tc(fun() ->
      lists:foreach(fun(_) -> erlang:term_to_binary(Response) end, lists:seq(1, N))
    end),
    ETF = erlang:term_to_binary(Response),

    %% --- ETF decode ---
    {ETFDecTime, _} = timer:tc(fun() ->
      lists:foreach(fun(_) -> erlang:binary_to_term(ETF) end, lists:seq(1, N))
    end),

    io:format("=== Server-side BEAM (~s iterations) ===~n~n", [commas(N)]),
    io:format("         Encode         Decode         Size~n"),
    io:format("ETF      ~7.1f us/op   ~7.1f us/op   ~p bytes~n",
      [ETFEncTime/N, ETFDecTime/N, byte_size(ETF)]),
    io:format("JSON     ~7.1f us/op   ~7.1f us/op   ~p bytes~n",
      [JsonEncTime/N, JsonDecTime/N, byte_size(JsonBin)]),
    io:format("~n"),
    io:format("ETF is ~.1fx faster to encode, ~.1fx faster to decode~n",
      [JsonEncTime/max(1, ETFEncTime), JsonDecTime/max(1, ETFDecTime)]),
    Pct = round((byte_size(JsonBin) - byte_size(ETF)) / byte_size(ETF) * 100),
    io:format("JSON is ~B% larger on the wire~n", [Pct]),
    ok.

%% --- JSON rebuild (mirrors libero's wire.gleam JSON decoder) ---

rebuild_term(null) -> nil;
rebuild_term(V) when is_number(V); is_binary(V); is_boolean(V) -> V;
rebuild_term(V) when is_list(V) -> [rebuild_term(E) || E <- V];
rebuild_term(V) when is_map(V) ->
    case V of
        #{<<"@">> := <<"dict">>, <<"v">> := Pairs} ->
            maps:from_list([{rebuild_term(K), rebuild_term(Val)}
                            || [K, Val] <- Pairs]);
        #{<<"@">> := Tag, <<"v">> := Fields} when is_binary(Tag) ->
            case Fields of
                [] -> binary_to_atom(Tag);
                _ -> list_to_tuple([binary_to_atom(Tag)
                                    | [rebuild_term(F) || F <- Fields]])
            end;
        _ -> V
    end;
rebuild_term(V) -> V.

commas(N) when N < 1000 -> integer_to_list(N);
commas(N) ->
    commas(N div 1000) ++ "," ++ string:right(integer_to_list(N rem 1000), 3, $0).
