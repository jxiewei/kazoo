-module(xf_port).

-export([start/1
        ,stop/1
        ,tts/3
        ]).

-include("media.hrl").

encode({'tts', Text}) -> [0, Text];
encode({'set_login_config', Config}) -> 
    [1, string:join(lists:map(fun({K, V}) -> string:join([K,wh_util:to_list(V)], "=") end, Config), ",")];
encode({'set_tts_params', Params}) ->
    [2, string:join(lists:map(fun({K, V}) -> string:join([K,wh_util:to_list(V)], "=") end, Params), ",")].

decode(<<0:8>>) -> 'ok';
decode(<<0:8, Data/binary>>) -> {'ok', Data};
decode(<<Ret:8, Data/binary>>) -> {'error', {Ret, Data}}.

start(Config) ->
    Port = open_port({spawn, "/usr/local/bin/xf_ttsc"}, [{packet, 4}, binary, nouse_stdio]),
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
        _ -> slice_tts(Port, slice_text(Text), <<>>)
    end.

slice_tts(_Port, [], Acc) -> 
    lager:debug("tts over"),
    {'ok', <<"RIFF", (byte_size(Acc)+36):32/little, "WAVE", "fmt ", 16:32/little, 
            1:16/little, 1:16/little, 16000:32/little, 32000:32/little, 2:16/little, 16:16/little, 
            "data", (byte_size(Acc)):32/little, Acc/binary>>};

slice_tts(Port, [Text|Others], Acc) ->
    lager:debug("ttsing ~p bytes", [byte_size(Text)]),
    case call_port(Port, {'tts', Text}) of
        {'error', _}=Error -> Error;
        {'ok', Data} -> 
            lager:debug("slice_tts succeed"),
            slice_tts(Port, Others, <<Acc/binary, Data/binary>>)
    end.

utf8_string_head(Bin, MaxChars) when is_binary(Bin) ->
    case byte_size(Bin) > MaxChars of
        'true' ->
            <<Bytes:MaxChars/binary, _/binary>> = Bin,
            ValidBytes = mochiutf8:valid_utf8_bytes(Bytes),
            SZ = byte_size(ValidBytes),
            <<ValidBytes:SZ/binary, Left/binary>> = Bin,
            {ValidBytes, Left};
        'false' -> {Bin, <<>>}
    end.

slice_text(<<>>) -> [];
slice_text(Bin) when is_binary(Bin) ->
    {Head, Tail} = utf8_string_head(Bin, 4096),
    [Head|slice_text(Tail)].

call_port(Port, Msg) ->
    Port ! {self(), {command, encode(Msg)}},
    receive 
        {Port, {data, Data}} ->
            lager:debug("got ~p bytes from port", [byte_size(Data)]),
            decode(Data);
        {'EXIT', Port, Reason} ->
            {'error', Reason};
        {Port, closed} ->
            {'error', 'closed'}
    end.
