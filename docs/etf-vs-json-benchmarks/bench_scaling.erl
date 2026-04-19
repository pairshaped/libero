%% Server-side scaling benchmark: ETF vs JSON at varying payload sizes.
%%
%% Simulates realistic competition data (teams, games, shots) modeled
%% after a real Brier event (~18 teams, 80 games, ~11,700 shots, ~1MB JSON).
%%
%% Usage:
%%   cd <project>/server
%%   erlc ../lib/libero/benchmarks/bench_scaling.erl
%%   erl -pa build/dev/erlang/*/ebin -noshell -eval 'bench_scaling:run(), halt().'
%%   rm bench_scaling.beam

-module(bench_scaling).
-export([run/0, run_generate/0]).

run() ->
    io:format("=== Server-side BEAM: ETF vs JSON scaling ===~n~n"),
    io:format("Payload                  ETF enc    JSON enc   Speedup   ETF dec    JSON dec   Speedup   ETF size    JSON size   Ratio~n"),
    io:format("~s~n", [lists:duplicate(120, $-)]),
    bench("5 discounts",     make_discounts_response(5),          100000),
    bench("50 discounts",    make_discounts_response(50),         20000),
    bench("18 teams",        make_competition_response(18, 0),    50000),
    bench("80 games no shots", make_competition_response(18, 80), 10000),
    bench("80 games + shots", make_competition_response_full(18, 80), 1000),
    ok.

%% Generate base64-encoded ETF + JSON for the client-side bench.
run_generate() ->
    J = 'gleam@json',
    Walk = walk_fn(J),
    lists:foreach(fun({Label, Response}) ->
        ETF = erlang:term_to_binary(Response),
        JsonBin = iolist_to_binary(J:to_string(Walk(Response))),
        io:format("~s~n~s~n~s~n",
          [Label, base64:encode(ETF), base64:encode(JsonBin)])
    end, [
        {<<"5_discounts">>, make_discounts_response(5)},
        {<<"50_discounts">>, make_discounts_response(50)},
        {<<"80_games_no_shots">>, make_competition_response(18, 80)},
        {<<"80_games_with_shots">>, make_competition_response_full(18, 80)}
    ]),
    halt().

bench(Label, Response, N) ->
    J = 'gleam@json',
    Walk = walk_fn(J),

    %% Warmup
    Warmup = max(100, N div 10),
    ETFWarm = erlang:term_to_binary(Response),
    JsonWarm = iolist_to_binary(J:to_string(Walk(Response))),
    lists:foreach(fun(_) ->
      erlang:term_to_binary(Response),
      erlang:binary_to_term(ETFWarm),
      J:to_string(Walk(Response)),
      rebuild_term(json:decode(JsonWarm))
    end, lists:seq(1, Warmup)),

    %% ETF encode
    {ETFEncUs, _} = timer:tc(fun() ->
      lists:foreach(fun(_) -> erlang:term_to_binary(Response) end, lists:seq(1, N))
    end),
    ETF = erlang:term_to_binary(Response),

    %% ETF decode
    {ETFDecUs, _} = timer:tc(fun() ->
      lists:foreach(fun(_) -> erlang:binary_to_term(ETF) end, lists:seq(1, N))
    end),

    %% JSON encode
    {JsonEncUs, _} = timer:tc(fun() ->
      lists:foreach(fun(_) -> J:to_string(Walk(Response)) end, lists:seq(1, N))
    end),
    JsonBin = iolist_to_binary(J:to_string(Walk(Response))),

    %% JSON decode + rebuild
    {JsonDecUs, _} = timer:tc(fun() ->
      lists:foreach(fun(_) -> rebuild_term(json:decode(JsonBin)) end, lists:seq(1, N))
    end),

    E_enc = ETFEncUs / N, J_enc = JsonEncUs / N,
    E_dec = ETFDecUs / N, J_dec = JsonDecUs / N,

    PadLabel = Label ++ lists:duplicate(max(1, 24 - length(Label)), $ ),
    ETFSize = fmt_bytes(byte_size(ETF)),
    JsonSize = fmt_bytes(byte_size(JsonBin)),
    SizeRatio = byte_size(JsonBin) / max(1.0, float(byte_size(ETF))),
    io:format("~s ~8.1f us ~8.1f us   ~5.1fx  ~8.1f us ~8.1f us   ~5.1fx  ~10s ~10s  ~4.1fx~n",
      [PadLabel, E_enc, J_enc, J_enc / max(0.1, E_enc),
       E_dec, J_dec, J_dec / max(0.1, E_dec),
       ETFSize, JsonSize, SizeRatio]).

%% --- Walk function (JSON encoder) ---

walk_fn(J) ->
    fun Walk(Term) ->
      if
        is_boolean(Term) -> J:bool(Term);
        Term =:= nil -> J:null();
        is_atom(Term) ->
          J:object([{<<"@">>, J:string(atom_to_binary(Term))},
                    {<<"v">>, J:preprocessed_array([])}]);
        is_integer(Term) -> J:int(Term);
        is_float(Term) -> J:float(Term);
        is_binary(Term) -> J:string(Term);
        is_list(Term) -> J:preprocessed_array([Walk(E) || E <- Term]);
        is_map(Term) ->
          Pairs = [J:preprocessed_array([Walk(K), Walk(V)])
                   || {K, V} <- maps:to_list(Term)],
          J:object([{<<"@">>, J:string(<<"dict">>)},
                    {<<"v">>, J:preprocessed_array(Pairs)}]);
        is_tuple(Term) ->
          [First | Rest] = tuple_to_list(Term),
          case is_atom(First) andalso not is_boolean(First) of
            true ->
              J:object([{<<"@">>, J:string(atom_to_binary(First))},
                        {<<"v">>, J:preprocessed_array([Walk(E) || E <- Rest])}]);
            false ->
              J:preprocessed_array([Walk(E) || E <- tuple_to_list(Term)])
          end
      end
    end.

%% --- Data generators ---

make_discounts_response(Count) ->
    Discounts = [make_discount(I) || I <- lists:seq(1, Count)],
    {ok, {admin_data, Discounts, Discounts,
      [{item_option, I, iolist_to_binary(["League ", integer_to_list(I)])}
       || I <- lists:seq(1, 4)],
      [{question_option, <<"gender">>, <<"Gender">>, <<"select">>}],
      #{<<"gender">> => [{<<"male">>, <<"Male">>}, {<<"female">>, <<"Female">>}]}
    }}.

make_discount(I) ->
    Name = iolist_to_binary(["Discount ", integer_to_list(I)]),
    {discount, I, 1, Name, {some, <<"Rabais">>},
     10.0 + float(I), I * 100, true, false, false, false, [],
     {some, 5}, {some, 65}, {some, male},
     {some, 14}, {some, two_or_more}, false,
     {some, <<"gender">>}, {some, <<"male">>}, none,
     1712000000 + I, 1712000000 + I}.

make_competition_response(TeamCount, GameCount) ->
    Teams = [make_team(I) || I <- lists:seq(1, TeamCount)],
    Games = [make_game(I, []) || I <- lists:seq(1, GameCount)],
    Standings = [make_standing(I) || I <- lists:seq(1, TeamCount)],
    {ok, {event, 26635, <<"2024 Tim Hortons Brier">>,
      <<"America/Regina">>, <<"CST">>,
      <<"2024-03-01">>, <<"2024-03-10">>,
      <<"complete">>, <<"Regina, SK">>, <<"Brandt Centre">>,
      Teams,
      [{stage, 1, <<"Round Robin">>, Standings, Games}]
    }}.

make_competition_response_full(TeamCount, GameCount) ->
    Teams = [make_team(I) || I <- lists:seq(1, TeamCount)],
    Shots = fun() -> [make_shot(E, S) || E <- lists:seq(1, 8), S <- lists:seq(1, 8)] end,
    Games = [make_game(I, Shots()) || I <- lists:seq(1, GameCount)],
    Standings = [make_standing(I) || I <- lists:seq(1, TeamCount)],
    {ok, {event, 26635, <<"2024 Tim Hortons Brier">>,
      <<"America/Regina">>, <<"CST">>,
      <<"2024-03-01">>, <<"2024-03-10">>,
      <<"complete">>, <<"Regina, SK">>, <<"Brandt Centre">>,
      Teams,
      [{stage, 1, <<"Round Robin">>, Standings, Games}]
    }}.

make_team(I) ->
    Name = iolist_to_binary(["Team ", integer_to_list(I)]),
    Lineup = [make_curler(I, Pos) || Pos <- [<<"fourth">>, <<"third">>,
              <<"second">>, <<"lead">>, <<"alternate">>]],
    {team, 113000 + I, Name, iolist_to_binary(["T", integer_to_list(I)]),
     <<"Coach Name">>, <<"Club Name">>, <<"City, Province">>, Lineup}.

make_curler(TeamI, Position) ->
    {curler, 1000 + TeamI * 10, Position, TeamI =:= 1,
     iolist_to_binary(["Player ", integer_to_list(TeamI)]),
     none, <<"Right">>, <<"Club">>, <<"male">>}.

make_standing(I) ->
    {standing, 113000 + I, I, 8, max(0, 9 - I), 0, min(8, I - 1),
     8.27 + float(I) * 0.5, I}.

make_game(I, Shots) ->
    EndScores = [0, 1, 0, 2, 0, 0, 1, 0],
    Side1 = {side, 113000 + I, 4, <<"won">>,
             true, <<"15:30">>, 45.5, EndScores, Shots},
    Side2 = {side, 113100 + I, 3, <<"lost">>,
             false, <<"12:15">>, 62.0, EndScores, Shots},
    {game, iolist_to_binary(io_lib:format("~8.16.0b", [I])),
     iolist_to_binary(["Game ", integer_to_list(I)]),
     <<"complete">>, [Side1, Side2]}.

make_shot(EndNum, ShotNum) ->
    {shot, <<"in">>, <<"draw">>, 3, 1781, EndNum, ShotNum}.

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

%% --- Formatting ---

fmt_bytes(B) when B < 1024 ->
    lists:flatten(io_lib:format("~B B", [B]));
fmt_bytes(B) when B < 1048576 ->
    lists:flatten(io_lib:format("~.1f KB", [B / 1024.0]));
fmt_bytes(B) ->
    lists:flatten(io_lib:format("~.1f MB", [B / 1048576.0])).
