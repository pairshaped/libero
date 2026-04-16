-module('server@generated@libero@websocket_ffi').
-export([decode_push_msg/1]).

decode_push_msg({libero_push, Frame}) when is_binary(Frame) ->
    {ok, Frame};
decode_push_msg(_) ->
    {error, nil}.
