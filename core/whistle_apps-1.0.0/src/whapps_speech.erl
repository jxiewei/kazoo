%%%-------------------------------------------------------------------
%%% @copyright (C) 2012-2014, 2600Hz INC
%%% @doc
%%% For TTS (Text To Speech), use the create/* methods
%%% To do ASR (Automatic Speech Recognition), there are two options:
%%%  1. asr_freeform/* -> takes an arbitrary file and tries to transcribe
%%%     it as best the engine can
%%%  2. asr_commands/* -> For greater accuracy, include a list of expected
%%%     words, and the ASR engine will try to determine which command is
%%%     said in the audio file.
%%% @end
%%% @contributors
%%%   Karl Anderson
%%%   James Aimonetti
%%%-------------------------------------------------------------------
-module(whapps_speech).

-include("whistle_apps.hrl").
-include_lib("whistle_media/include/wh_media.hrl").
-include_lib("kazoo_oauth/include/kazoo_oauth_types.hrl").

-export([create/1
         ,create/2
         ,create/3
         ,create/4
         ,create/5
        ]).
-export([asr_freeform/1
         ,asr_freeform/2
         ,asr_freeform/3
         ,asr_freeform/4
        ]).
-export([asr_commands/2
         ,asr_commands/3
         ,asr_commands/4
         ,asr_commands/5
        ]).

-define(MOD_CONFIG_CAT, <<"speech">>).

-type provider_errors() :: 'invalid_voice' | 'unknown_provider'.
-type provider_return() :: {'error', provider_errors()} |
                           ibrowse_ret() |
                           {'ibrowse_req_id', ibrowse_req_id()}.
-type create_resp() :: {'ok', ibrowse_req_id()} |
                       provider_return() |
                       {'ok', ne_binary(), ne_binary()} | %% {'ok', ContentType, BinaryData}
                       {'error', 'tts_provider_failure', binary()}.

-type asr_resp() :: {'ok', ibrowse_req_id()} |
                    {'ok', wh_json:object()} | %% {'ok', JObj}
                    {'error', provider_errors()} |
                    {'error',  'asr_provider_failure', wh_json:object()}.

%%------------------------------------------------------------------------------
%% Create a tts audio file using a configured provider
%%------------------------------------------------------------------------------
-spec create(ne_binary()) -> create_resp().
create(Text) ->
    create(Text, <<"female/en-US">>).

-spec create(ne_binary(), ne_binary()) -> create_resp().
create(Text, Voice) ->
    create(Text, Voice, <<"wav">>).

-spec create(ne_binary(), ne_binary(), ne_binary()) -> create_resp().
create(Text, Voice, Format) ->
    create(Text, Voice, Format, []).

-spec create(ne_binary(), ne_binary(), ne_binary(), wh_proplist()) -> create_resp().
create(Text, Voice, Format, Options) ->
    Provider = whapps_config:get_binary(?MOD_CONFIG_CAT, <<"tts_provider">>, <<"ispeech">>),
    create(Provider, Text, Voice, Format, Options).

-spec create(api_binary(), ne_binary(), ne_binary(), ne_binary(), wh_proplist()) -> create_resp().
create('undefined', Text, Voice, Format, Options) ->
    create(Text, Voice, Format, Options);
create(<<"ispeech">> = Engine, Text, Voice, Format, Options) ->
    VoiceMappings = [{<<"female/en-US">>, <<"usenglishfemale">>}
                     ,{<<"male/en-US">>, <<"usenglishmale">>}
                     ,{<<"female/en-CA">>, <<"caenglishfemale">>}
                     ,{<<"female/en-AU">>, <<"auenglishfemale">>}
                     ,{<<"female/en-GB">>, <<"ukenglishfemale">>}
                     ,{<<"male/en-GB">>, <<"ukenglishmale">>}
                     ,{<<"female/es-US">>, <<"usspanishfemale">>}
                     ,{<<"male/es-US">>, <<"usspanishmale">>}
                     ,{<<"female/us-US">>, <<"usspanishfemale">>}
                     ,{<<"female/zh-CN">>, <<"chchinesefemale">>}
                     ,{<<"male/zh-CN">>, <<"chchinesemale">>}
                     ,{<<"female/zh-HK">>, <<"hkchinesefemale">>}
                     ,{<<"female/zh-TW">>, <<"twchinesefemale">>}
                     ,{<<"female/ja-JP">>, <<"jpjapanesefemale">>}
                     ,{<<"male/ja-JP">>, <<"jpjapanesemale">>}
                     ,{<<"female/ko-KR">>, <<"krkoreanfemale">>}
                     ,{<<"male/ko-KR">>, <<"krkoreanmale">>}
                     ,{<<"female/da-DK">>, <<"eurdanishfemale">>}
                     ,{<<"female/de-DE">>, <<"eurgermanfemale">>}
                     ,{<<"male/de-DE">>, <<"eurgermanmale">>}
                     ,{<<"female/ca-ES">>, <<"eurcatalanfemale">>}
                     ,{<<"female/es-ES">>, <<"eurspanishfemale">>}
                     ,{<<"male/es-ES">>, <<"eurspanishmale">>}
                     ,{<<"female/fi-FI">>, <<"eurfinnishfemale">>}
                     ,{<<"female/fr-CA">>, <<"cafrenchfemale">>}
                     ,{<<"male/fr-CA">>, <<"cafrenchmale">>}
                     ,{<<"female/fr-FR">>, <<"eurfrenchfemale">>}
                     ,{<<"male/fr-FR">>, <<"eurfrenchmale">>}
                     ,{<<"female/it-IT">>, <<"euritalianfemale">>}
                     ,{<<"male/it-IT">>, <<"euritalianmale">>}
                     ,{<<"female/nb-NO">>, <<"eurnorwegianfemale">>}
                     ,{<<"female/nl-NL">>, <<"eurdutchfemale">>}
                     ,{<<"female/pl-PL">>, <<"eurpolishfemale">>}
                     ,{<<"female/pt-BR">>, <<"brportuguesefemale">>}
                     ,{<<"female/pt-PT">>, <<"eurportuguesefemale">>}
                     ,{<<"male/pt-PT">>, <<"eurportuguesemale">>}
                     ,{<<"female/ru-RU">>, <<"rurussianfemale">>}
                     ,{<<"male/ru-RU">>, <<"rurussianmale">>}
                     ,{<<"female/sv-SE">>, <<"swswedishfemale">>}
                     ,{<<"female/hu-HU">>, <<"huhungarianfemale">>}
                     ,{<<"female/cs-CZ">>, <<"eurczechfemale">>}
                     ,{<<"female/tr-TR">>, <<"eurturkishfemale">>}
                     ,{<<"male/tr-TR">>, <<"eurturkishmale">>}
                    ],
    case props:get_value(Voice, VoiceMappings) of
        'undefined' ->
            {'error', 'invalid_voice'};
        ISpeechVoice ->
            BaseUrl = whapps_config:get_string(?MOD_CONFIG_CAT, <<"tts_url">>, <<"http://api.ispeech.org/api/json">>),
            Props = [{<<"text">>, Text}
                     ,{<<"voice">>, ISpeechVoice}
                     ,{<<"format">>, Format}
                     ,{<<"action">>, <<"convert">>}
                     ,{<<"apikey">>, whapps_config:get_binary(?MOD_CONFIG_CAT, <<"tts_api_key">>, <<>>)}
                     ,{<<"speed">>, whapps_config:get_integer(?MOD_CONFIG_CAT, <<"tts_speed">>, 0)}
                     ,{<<"startpadding">>, whapps_config:get_integer(?MOD_CONFIG_CAT, <<"tts_start_padding">>, 1)}
                     ,{<<"endpadding">>, whapps_config:get_integer(?MOD_CONFIG_CAT, <<"tts_end_padding">>, 0)}
                    ],
            Headers = [{"Content-Type", "application/json; charset=UTF-8"}],
            HTTPOptions = [{'response_format', 'binary'} | Options],
            Body = wh_json:encode(wh_json:from_list(Props)),
            Response = ibrowse:send_req(BaseUrl, Headers, 'post', Body, HTTPOptions),
            create_response(Engine, Response)
    end;

create(<<"bing">> = Engine, Text, Voice, Format, _Options) ->
    VoiceMappings = [{<<"male/en-US">>, <<"en-us">>}
                     ,{<<"male/zh-CN">>, <<"zh-cn">>}
                    ],
    case props:get_value(Voice, VoiceMappings) of
        'undefined' ->
            {'error', 'invalid_voice'};
        BingVoice ->
            {'ok', Token} = get_token(Engine),
            BaseUrl = whapps_config:get_string(?MOD_CONFIG_CAT, <<"tts_url">>, <<"http://api.microsofttranslator.com/V2/Http.svc/Speak">>),
            Fields = [{"language", wh_util:to_list(BingVoice)}
                      ,{"format", "audio/"++wh_util:to_list(Format)}
                      ,{"options", "MaxQuality"}
                      ,{"text", wh_util:uri_encode(wh_util:to_list(Text))}
                     ],
            QS = string:join(lists:append(lists:map(fun({K,V}) -> [string:join([K,V], "=")] end, Fields)), "&"),
            Headers = [{"Authorization", "Bearer "++Token}],
            Response = ibrowse:send_req(BaseUrl++"?"++QS, Headers, 'get'),
            create_response(Engine, Response)
    end;

%%FIXME: google tts likely have some limitation in addition to 100 chars limit.
%%Without sleep 1s between requests, the third req will fail cetainly.
%%With sleep, it still fails often(tcp RESET by peer).
create(<<"google">> = Engine, Text, Voice, _Format, _Options) ->
    VoiceMappings = [{<<"female/en-US">>, <<"en-us">>}
                     ,{<<"female/zh-CN">>, <<"zh_CN">>}
                    ],
    case props:get_value(Voice, VoiceMappings) of
        'undefined' ->
            {'error', 'invalid_voice'};
        BingVoice ->
            TextL = slice_text(Engine, Text),
            Total = length(TextL),
            {'ok', CT, Content, _Idx} = 
                lists:foldl(
                  fun(E, Acc) -> 
                        {'ok', CT, C, Idx} = Acc,
                        Response = google_tts(BingVoice, E, Total, Idx),
                        Acc1 = case Response of
                            {'ok', CT1, C1} -> {'ok', CT1, <<C/binary, (wh_util:to_binary(C1))/binary>>, Idx+1};
                            _ -> {'ok', CT, C, Idx+1}
                        end,
                        timer:sleep(1000),
                        Acc1 
                  end, {'ok', 'undefined', <<>>, 0}, TextL),
            {'ok', CT, Content}
            %google_tts(BingVoice, Text, 1, 0)
    end;

create(<<"xunfei">> = Engine, Text, Voice, _Format, _Options) ->
    VoiceMappings = [{<<"female/en-US">>, [{"ent","inet65_en"}, {"vcn","Catherine"}]}
                     ,{<<"female/zh-CN">>, [{"ent","inet65"}, {"vcn","xiaoyan"}]}
                     ,{<<"male/en-US">>, [{"ent","inet65_en"}, {"vcn","henry"}]}
                     ,{<<"male/zh-CN">>, [{"ent","inet65"}, {"vcn","xiaoyu"}]}
                    ],
    case props:get_value(Voice, VoiceMappings) of
        'undefined' ->
            {'error', 'invalid_voice'};
        XVoice ->
            {'ok', [[Home]]} = init:get_argument('home'),
            {'ok',Port} = xf_port:start([{"appid", "541a5dbd"}, {"work_dir", Home}]),
            lager:debug("jerry -- voice ~p", [XVoice]),
            {'ok', Data} = xf_port:tts(Port, XVoice++
                                                 [{"aue", "speex-wb"}
                                                 ,{"auf", "audio/L16"}
                                                 ,{"rate", "16000"}
                                                 ,{"spd", "5"}
                                                 ,{"vol", "5"}
                                                 ,{"tte", "utf8"}
                                                ], Text),
            lager:debug("xf_tts returned ~p bytes", [byte_size(Data)]),
            xf_port:stop(Port),
            {'ok', <<"audio/wav">>, Data} 
    end;


create(_, _, _, _, _) ->
    {'error', 'unknown_provider'}.

%%------------------------------------------------------------------------------
%% Transcribe the audio binary
%%------------------------------------------------------------------------------
-spec asr_freeform(binary()) -> asr_resp().
-spec asr_freeform(binary(), ne_binary()) -> asr_resp().
-spec asr_freeform(binary(), ne_binary(), ne_binary()) -> asr_resp().
-spec asr_freeform(binary(), ne_binary(), ne_binary(), wh_proplist()) -> asr_resp().
asr_freeform(Content) ->
    asr_freeform(Content, <<"application/wav">>).
asr_freeform(Content, ContentType) ->
    asr_freeform(Content, ContentType, <<"en-US">>).
asr_freeform(Content, ContentType, Locale) ->
    asr_freeform(Content, ContentType, Locale, []).
asr_freeform(Content, ContentType, Locale, Options) ->
    Provider = whapps_config:get_binary(?MOD_CONFIG_CAT, <<"asr_provider">>, <<>>),
    case wh_util:is_empty(Provider) of
        'true' -> {'error', 'no_asr_provider'};
        'false' -> maybe_convert_content(Content, ContentType, Locale, Options)
    end.

-spec maybe_convert_content(binary(), ne_binary(), ne_binary(), wh_proplist()) -> provider_return().
maybe_convert_content(Content, ContentType, Locale, Options) ->
    ContentTypes = whapps_config:get(?MOD_CONFIG_CAT
                                     ,<<"asr_content_types">>
                                     ,[<<"application/mpeg">>
                                       ,<<"application/wav">>
                                      ]),
    case lists:member(ContentType, ContentTypes) of
        'true' -> attempt_asr_freeform(Content, ContentType, Locale, Options);
        'false' ->
            ConvertTo = whapps_config:get_binary(?MOD_CONFIG_CAT
                                                 ,<<"asr_prefered_content_type">>
                                                 ,<<"application/mpeg">>),
            case convert_content(Content, ContentType, ConvertTo) of
                'error' -> {'error', 'unsupported_content_type'};
                Converted ->
                    attempt_asr_freeform(Converted, ContentType, Locale, Options)
            end
    end.

-spec attempt_asr_freeform(binary(), ne_binary(), ne_binary(), wh_proplist()) -> provider_return().
attempt_asr_freeform(Content, ContentType, Locale, Options) ->
    Provider = whapps_config:get_binary(?MOD_CONFIG_CAT, <<"asr_provider">>, <<>>),
    case attempt_asr_freeform(Provider, Content, ContentType, Locale, Options) of
        {'error', _R}=E ->
            lager:debug("asr failed with error ~p", [_R]),
            E;
        {'ibrowse_req_id', ReqID} ->
            lager:debug("streaming response ~p to provided option: ~p", [ReqID, props:get_value(stream_to, Options)]),
            {'ok', ReqID};
        {'ok', "200", _Headers, Content} ->
            lager:debug("asr of media succeeded: ~s", [Content]),
            {'ok', wh_json:decode(Content)};
        {'ok', Code, _Hdrs, Content} ->
            lager:debug("asr of media failed with code ~s", [Code]),
            lager:debug("resp: ~s", [Content]),
            {'error', 'asr_provider_failure', wh_json:decode(Content)}
    end.

-spec attempt_asr_freeform(api_binary(), binary(), ne_binary(), ne_binary(), wh_proplist()) -> provider_return().
attempt_asr_freeform(_, <<>>, _, _, _) -> {'error', 'no_content'};
attempt_asr_freeform(<<"ispeech">>, Bin, ContentType, Locale, Options) ->
    BaseUrl = whapps_config:get_string(?MOD_CONFIG_CAT, <<"asr_url">>, <<"http://api.ispeech.org/api/json">>),
    lager:debug("sending request to ~s", [BaseUrl]),
    Props = [{<<"apikey">>, whapps_config:get_binary(?MOD_CONFIG_CAT, <<"asr_api_key">>, <<>>)}
             ,{<<"action">>, <<"recognize">>}
             ,{<<"freeform">>, <<"1">>}
             ,{<<"content-type">>, ContentType}
             ,{<<"output">>, <<"json">>}
             ,{<<"locale">>, Locale}
             ,{<<"audio">>, base64:encode(Bin)}
            ],
    Headers = [{"Content-Type", "application/json"}],
    HTTPOptions = [{'response_format', 'binary'} | Options],
    Body = wh_json:encode(wh_json:from_list(Props)),
    lager:debug("req body: ~s", [Body]),
    ibrowse:send_req(BaseUrl, Headers, 'post', Body, HTTPOptions);
attempt_asr_freeform(_, _, _, _, _) ->
    {'error', 'unknown_provider'}.

%%------------------------------------------------------------------------------
%% Transcribe the audio binary
%%------------------------------------------------------------------------------
-spec asr_commands(ne_binary(), ne_binaries()) -> asr_resp().
-spec asr_commands(ne_binary(), ne_binaries(), ne_binary()) -> asr_resp().
-spec asr_commands(ne_binary(), ne_binaries(), ne_binary(), ne_binary()) -> asr_resp().
-spec asr_commands(ne_binary(), ne_binaries(), ne_binary(), ne_binary(), wh_proplist()) -> asr_resp().
-spec asr_commands(ne_binary(), ne_binary(), ne_binaries(), ne_binary(), ne_binary(), wh_proplist()) -> provider_return().
asr_commands(Bin, Commands) ->
    asr_commands(Bin, Commands, <<"application/wav">>).
asr_commands(Bin, Commands, ContentType) ->
    asr_commands(Bin, Commands, ContentType, <<"en-US">>).
asr_commands(Bin, Commands, ContentType, Locale) ->
    asr_commands(Bin, Commands, ContentType, Locale, []).
asr_commands(Bin, Commands, ContentType, Locale, Options) ->
    Provider = whapps_config:get_binary(?MOD_CONFIG_CAT, <<"asr_provider">>, <<"ispeech">>),
    case asr_commands(Provider, Bin, Commands, ContentType, Locale, Options) of
        {'error', _R}=E ->
            lager:debug("asr failed with error ~p", [_R]),
            E;
        {'ibrowse_req_id', ReqID} ->
            lager:debug("streaming response ~p to provided option: ~p", [ReqID, props:get_value(stream_to, Options)]),
            {'ok', ReqID};
        {'ok', "200", _Headers, Content} ->
            lager:debug("asr of media succeeded: ~s", [Content]),
            {'ok', wh_json:decode(Content)};
        {'ok', Code, _Hdrs, Content} ->
            lager:debug("asr of media failed with code ~s", [Code]),
            lager:debug("resp: ~s", [Content]),
            {'error', 'asr_provider_failure', wh_json:decode(Content)}
    end.

asr_commands(<<"ispeech">>, Bin, Commands, ContentType, Locale, Options) ->
    BaseUrl = whapps_config:get_string(?MOD_CONFIG_CAT, <<"asr_url">>, <<"http://api.ispeech.org/api/json">>),

    Commands1 = wh_util:join_binary(Commands, <<"|">>),

    lager:debug("sending request to ~s", [BaseUrl]),

    Props = [{<<"apikey">>, whapps_config:get_binary(?MOD_CONFIG_CAT, <<"asr_api_key">>, <<>>)}
             ,{<<"action">>, <<"recognize">>}
             ,{<<"alias">>, <<"command1|YESNOMAYBE">>}
             ,{<<"YESNOMAYBE">>, Commands1}
             ,{<<"command1">>, <<"say %YESNOMAYBE%">>}
             ,{<<"content-type">>, ContentType}
             ,{<<"output">>, <<"json">>}
             ,{<<"locale">>, Locale}
             ,{<<"audio">>, base64:encode(Bin)}
            ],
    Headers = [{"Content-Type", "application/json"}],
    HTTPOptions = [{'response_format', 'binary'} | Options],

    Body = wh_json:encode(wh_json:from_list(Props)),
    lager:debug("req body: ~s", [Body]),

    ibrowse:send_req(BaseUrl, Headers, 'post', Body, HTTPOptions);
asr_commands(_, _, _, _, _, _) ->
    {'error', 'unknown_provider'}.

-spec create_response(ne_binary(), ibrowse_ret()) ->
                             {'ok', ibrowse_req_id()} |
                             {'ok', ne_binary(), ne_binary()} |
                             {'error', 'tts_provider_failure', binary()}.
create_response(_Engine, {'error', _R}) ->
    lager:warning("creating speech file failed with error ~p", [_R]),
    {'error', 'tts_provider_failure', <<"unexpected error encountered accessing provider">>};
create_response(_Engine, {'ibrowse_req_id', ReqID}) ->
    lager:debug("speech file streaming as ~p", [ReqID]),
    {'ok', ReqID};
create_response(_Engine, {'ok', "200", Headers, Content}) ->
    ContentType = props:get_value("Content-Type", Headers),
    ContentLength = props:get_value("Content-Length", Headers),
    lager:debug("created speech file ~s of length ~s", [ContentType, ContentLength]),
    {'ok', wh_util:to_binary(ContentType), wh_util:to_binary(Content)};
create_response(Engine, {'ok', Code, RespHeaders, Content}) ->
    lager:warning("creating speech file failed with code ~s: ~s", [Code, Content]),
    [lager:debug("hdr: ~p", [H]) || H <- RespHeaders],

    {'error', 'tts_provider_failure', create_error_response(Engine, RespHeaders, Content)}.

-spec create_error_response(ne_binary(), wh_proplist(), binary()) -> binary().
create_error_response(<<"ispeech">>, _RespHeaders, Content) ->
    wh_json:get_value(<<"message">>, wh_json:decode(Content));
create_error_response(_Engine, _RespHeaders, Content) ->
    Content.

-spec convert_content(binary(), ne_binary(), ne_binary()) -> binary() | 'error'.
convert_content(Content, <<"audio/mpeg">>, <<"application/wav">> = _ContentType) ->
    Mp3File = tmp_file_name(<<"mp3">>),
    WavFile = tmp_file_name(<<"wav">>),
    _ = file:write_file(Mp3File, Content),
    Cmd = io_lib:format("lame --decode ~s ~s &> /dev/null && echo -n \"success\"", [Mp3File, WavFile]),
    _ = os:cmd(Cmd),
    _ = file:delete(Mp3File),
    case file:read_file(WavFile) of
        {'ok', WavContent} ->
            _ = file:delete(WavFile),
            WavContent;
        {'error', _R} ->
            lager:info("unable to convert mpeg to wav: ~p", [_R]),
            'error'
    end;
convert_content(_, ContentType, ConvertTo) ->
    lager:info("unsupported conversion from %s to %s", [ContentType, ConvertTo]),
    'error'.

-spec tmp_file_name(ne_binary()) -> string().
tmp_file_name(Ext) ->
    wh_util:to_list(<<"/tmp/", (wh_util:rand_hex_binary(10))/binary, "_voicemail.", Ext/binary>>).


google_tts(Language, Text, Total, Idx) -> 
    BaseUrl = whapps_config:get_string(?MOD_CONFIG_CAT, <<"tts_url">>, <<"http://translate.google.com/translate_tts">>),
    Fields = [{"tl", wh_util:to_list(Language)}
              ,{"ie", "UTF-8"}
              ,{"q", wh_util:uri_encode(wh_util:to_list(Text))}
              ,{"textlen", wh_util:to_list(byte_size(Text))}
              ,{"idx", wh_util:to_list(Idx)}
              ,{"total", wh_util:to_list(Total)}
             ],
    %QS = string:join(lists:append(lists:map(fun({K,V}) -> [string:join([K,V], "=")] end, Fields)), "&"),
    QS = mochiweb_util:urlencode(Fields),
    Headers = [{"Referer", "http://www.gstatic.com/translate/sound_player2.swf"}
               ,{"User-Agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_7_3) " 
                               "AppleWebKit/535.19 (KHTML, like Gecko) Chrome/18.0.1025.163 Safari/535.19"
                }
              ],
    Response = ibrowse:send_req(BaseUrl++"?"++QS, Headers, 'get', [], [{max_sessions, 100}, {max_pipeline_size, 100}, {trace, 'true'}]),
    lager:debug("jerry -- sending req ~s", [BaseUrl++"?"++QS]),
    create_response(<<"google">>, Response).

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

slice_text(_, <<>>) -> [];
slice_text(<<"google">>=Engine, Bin) when is_binary(Bin) ->
    {Head, Tail} = utf8_string_head(Bin, 99),
    [Head|slice_text(Engine, Tail)].


-spec get_token(ne_binary()) -> {'ok', string()}.
get_token(<<"bing">>=Engine) ->
    case wh_cache:peek_local(?TTS_TOKEN_CACHE, Engine) of
        {'ok', _Auth}=OK -> OK;
        {'error', _} ->
            AppId = whapps_config:get(?MOD_CONFIG_CAT, <<Engine/binary, "_tts_oauth_app">>),
            %Bing returns url-encoded token, thus not necessary to call authorization_header here
            {'ok', #oauth_token{expires=Expires, token=Token}} = kazoo_oauth_util:token(AppId),
            wh_cache:store_local(?TTS_TOKEN_CACHE, Engine, Token, [{'expires', Expires }]),
            {'ok', Token}
    end.

