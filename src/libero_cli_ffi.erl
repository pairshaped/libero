-module(libero_cli_ffi).
-export([run_command/2]).

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
