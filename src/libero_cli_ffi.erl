-module(libero_cli_ffi).
-export([run_executable_capturing/2, find_executable/1, get_env/1]).

%% Run an executable, capturing stdout+stderr (merged) into a binary.
%% Returns {ExitStatus, Output} so callers can surface diagnostics
%% when the command fails. Used for tools whose output should not
%% be printed unconditionally (e.g. `gleam format`).
run_executable_capturing(Path, Args) ->
    Port = erlang:open_port(
        {spawn_executable, unicode:characters_to_list(Path)},
        [{args, [unicode:characters_to_list(A) || A <- Args]},
         exit_status, stderr_to_stdout, binary]
    ),
    wait_for_port_capturing(Port, []).

wait_for_port_capturing(Port, Acc) ->
    receive
        {Port, {exit_status, Status}} ->
            Output = iolist_to_binary(lists:reverse(Acc)),
            {Status, Output};
        {Port, {data, Data}} ->
            wait_for_port_capturing(Port, [Data | Acc])
    end.

%% Find an executable on PATH. Returns {some, Path} or none.
find_executable(Name) ->
    case os:find_executable(unicode:characters_to_list(Name)) of
        false -> none;
        Path -> {some, unicode:characters_to_binary(Path)}
    end.

%% Look up an environment variable. Returns {some, Value} or none.
%% os:getenv/1 takes a charlist, so we convert from the Gleam binary first.
%% The result is a charlist too, so we convert back.
get_env(Name) ->
    case os:getenv(unicode:characters_to_list(Name)) of
        false -> none;
        Value -> {some, unicode:characters_to_binary(Value)}
    end.
