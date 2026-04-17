-module(libero_cli_ffi).
-export([run_command/2]).

%% Run an external command with arguments, inheriting stdio.
%% Returns the exit code as an integer.
run_command(Command, Args) ->
    Port = open_port(
        {spawn_executable, os:find_executable(Command)},
        [exit_status, stderr_to_stdout, {args, Args}]
    ),
    wait_for_exit(Port).

wait_for_exit(Port) ->
    receive
        {Port, {data, Data}} ->
            io:put_chars(Data),
            wait_for_exit(Port);
        {Port, {exit_status, Code}} ->
            Code
    end.
