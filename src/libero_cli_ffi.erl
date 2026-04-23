-module(libero_cli_ffi).
-export([run_command/2, run_executable/2, find_executable/1]).

%% Run a command in a given directory, inheriting stdio.
%% Returns the exit code as an integer.
run_command(Dir, Args) ->
    DirStr = binary_to_list(Dir),
    ArgStrs = [binary_to_list(A) || A <- Args],
    case os:find_executable("gleam") of
        false -> 127;
        Exe ->
            Port = open_port(
                {spawn_executable, Exe},
                [exit_status, stderr_to_stdout, {cd, DirStr}, {args, ArgStrs}]
            ),
            wait_for_exit(Port)
    end.

wait_for_exit(Port) ->
    receive
        {Port, {data, Data}} ->
            io:put_chars(Data),
            wait_for_exit(Port);
        {Port, {exit_status, Code}} ->
            Code
    end.

%% Run an executable with args, discarding stdout/stderr.
%% Returns the exit status as an integer.
run_executable(Path, Args) ->
    Port = erlang:open_port(
        {spawn_executable, unicode:characters_to_list(Path)},
        [{args, [unicode:characters_to_list(A) || A <- Args]},
         exit_status, stderr_to_stdout]
    ),
    wait_for_port(Port).

wait_for_port(Port) ->
    receive
        {Port, {exit_status, Status}} -> Status;
        {Port, {data, _}} -> wait_for_port(Port)
    end.

%% Find an executable on PATH. Returns {some, Path} or none.
find_executable(Name) ->
    case os:find_executable(unicode:characters_to_list(Name)) of
        false -> none;
        Path -> {some, unicode:characters_to_binary(Path)}
    end.
