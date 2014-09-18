-module(xf_port).

-export([start/1
        ,stop/1
        ,tts/3
        ]).

-include("media.hrl").

encode({'tts', Text}) -> [0, Text];
encode({'set_login_config', Config}) -> 
    [1, string:join(lists:map(fun({K, V}) -> string:join([K,V], "=") end, Config), ",")];
encode({'set_tts_params', Params}) ->
    [2, string:join(lists:map(fun({K, V}) -> string:join([K,V], "=") end, Params), ",")].

decode([0]) -> 'ok';
decode([0|Data]) -> {'ok', wh_util:to_binary(Data)};
decode([Ret|Data]) -> {'error', {Ret, Data}}.

start(Config) ->
    Port = open_port({spawn, "/usr/local/bin/xf_ttsc"}, [{packet, 4}]),
    case call_port(Port, {'set_login_config', Config}) of
        {'error', _}=Error -> Error;
        _ -> {'ok', Port}
    end.

stop(Port) ->
    Port ! {self(), close},
    receive 
        {Port, closed} -> 'ok'
    end.

tts(Port, Params, Text) ->
    case call_port(Port, {'set_tts_params', Params}) of
        {'error', _}=Error -> Error;
        _ -> call_port(Port, {'tts', Text})
    end.

call_port(Port, Msg) ->
    Port ! {self(), {command, encode(Msg)}},
    receive 
        {Port, {data, Data}} ->
            lager:debug("jerry -- got ~p bytes from port", [length(Data)]),
            decode(Data);
        {'EXIT', Port, Reason} ->
            {'error', Reason}
    end.   
