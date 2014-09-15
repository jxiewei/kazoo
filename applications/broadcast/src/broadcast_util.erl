
-module(broadcast_util).

-include("broadcast.hrl").

-export([build_offnet_request/3
        ,start_recording/1
        ,stop_recording/1
        ,create_call/4]).

-spec build_offnet_request(wh_json:object(), whapps_call:call(), ne_binary()) -> wh_proplist().
build_offnet_request(Data, Call, ResponseQueue) ->
    {CIDNumber, CIDName} = get_caller_id(Data, Call),
    props:filter_undefined([{<<"Resource-Type">>, <<"originate">>}
                            ,{<<"Application-Name">>, <<"park">>}
                            ,{<<"Outbound-Caller-ID-Name">>, CIDName}
                            ,{<<"Outbound-Caller-ID-Number">>, CIDNumber}
                            ,{<<"Msg-ID">>, wh_util:rand_hex_binary(6)}
                            ,{<<"Account-ID">>, whapps_call:account_id(Call)}
                            ,{<<"Account-Realm">>, whapps_call:from_realm(Call)}
                            ,{<<"Media">>, wh_json:get_value(<<"Media">>, Data)}
                            ,{<<"Timeout">>, wh_json:get_value(<<"timeout">>, Data)}
                            ,{<<"Ringback">>, wh_json:get_value(<<"ringback">>, Data)}
                            ,{<<"Format-From-URI">>, wh_json:is_true(<<"format_from_uri">>, Data)}
                            ,{<<"Hunt-Account-ID">>, get_hunt_account_id(Data, Call)}
                            ,{<<"Flags">>, get_flags(Data, Call)}
                            ,{<<"Ignore-Early-Media">>, get_ignore_early_media(Data)}
                            ,{<<"Force-Fax">>, get_force_fax(Call)}
                            ,{<<"SIP-Headers">>,get_sip_headers(Data, Call)}
                            ,{<<"To-DID">>, get_to_did(Data, Call)}
                            ,{<<"From-URI-Realm">>, get_from_uri_realm(Data, Call)}
                            ,{<<"Bypass-E164">>, get_bypass_e164(Data)}
                            ,{<<"Diversions">>, get_diversions(Call)}
                            ,{<<"Inception">>, get_inception(Call)}
                            ,{<<"Outbound-Call-ID">>, whapps_call:call_id(Call)}
                            ,{<<"Custom-Channel-Vars">>, wh_json:from_list([{<<"Authorizing-ID">>, whapps_call:authorizing_id(Call)}
                                                              ,{<<"Authorizing-Type">>, whapps_call:authorizing_type(Call)}
                                                              ])}
                            | wh_api:default_headers(ResponseQueue, ?APP_NAME, ?APP_VERSION)
                           ]).


-spec get_bypass_e164(wh_json:object()) -> boolean().
get_bypass_e164(Data) ->
    wh_json:is_true(<<"do_not_normalize">>, Data)
        orelse wh_json:is_true(<<"bypass_e164">>, Data).

-spec get_from_uri_realm(wh_json:object(), whapps_call:call()) -> api_binary().
get_from_uri_realm(Data, Call) ->
    case wh_json:get_ne_value(<<"from_uri_realm">>, Data) of
        'undefined' -> maybe_get_call_from_realm(Call);
        Realm -> Realm
    end.

-spec maybe_get_call_from_realm(whapps_call:call()) -> api_binary().
maybe_get_call_from_realm(Call) ->
    case whapps_call:from_realm(Call) of
        'undefined' -> get_account_realm(Call);
        Realm -> Realm
    end.

-spec get_account_realm(whapps_call:call()) -> api_binary().
get_account_realm(Call) ->
    AccountId = whapps_call:account_id(Call),
    AccountDb = whapps_call:account_db(Call),
    case couch_mgr:open_cache_doc(AccountDb, AccountId) of
        {'ok', JObj} -> wh_json:get_value(<<"realm">>, JObj);
        {'error', _} -> 'undefined'
    end.


-spec get_caller_id(wh_json:object(), whapps_call:call()) -> {api_binary(), api_binary()}.
get_caller_id(Data, Call) ->
    Type = wh_json:get_value(<<"caller_id_type">>, Data, <<"external">>),
    cf_attributes:caller_id(Type, Call).

-spec get_hunt_account_id(wh_json:object(), whapps_call:call()) -> api_binary().
get_hunt_account_id(Data, Call) ->
    case wh_json:is_true(<<"use_local_resources">>, Data, 'true') of
        'false' -> 'undefined';
        'true' ->
            AccountId = whapps_call:account_id(Call),
            wh_json:get_value(<<"hunt_account_id">>, Data, AccountId)
    end.

-spec get_to_did(wh_json:object(), whapps_call:call()) -> ne_binary().
get_to_did(Data, Call) ->
    case wh_json:is_true(<<"bypass_e164">>, Data) of
        'false' -> get_to_did(Data, Call, whapps_call:request_user(Call));
        'true' ->
            Request = whapps_call:request(Call),
            [RequestUser, _] = binary:split(Request, <<"@">>),
            case wh_json:is_true(<<"do_not_normalize">>, Data) of
                'false' -> get_to_did(Data, Call, RequestUser);
                'true' -> RequestUser
            end
    end.

-spec get_to_did(wh_json:object(), whapps_call:call(), ne_binary()) -> ne_binary().
get_to_did(_Data, Call, Number) ->
    case cf_endpoint:get(Call) of
        {'ok', Endpoint} ->
            case wh_json:get_value(<<"dial_plan">>, Endpoint, []) of
                [] -> Number;
                DialPlan -> cf_util:apply_dialplan(Number, DialPlan)
            end;
        {'error', _ } -> Number
    end.

-spec get_sip_headers(wh_json:object(), whapps_call:call()) -> api_object().
get_sip_headers(Data, Call) ->
    Routines = [fun(J) ->
                        case wh_json:is_true(<<"emit_account_id">>, Data) of
                            'false' -> J;
                            'true' ->
                                wh_json:set_value(<<"X-Account-ID">>, whapps_call:account_id(Call), J)
                        end
                end
               ],
    CustomHeaders = wh_json:get_value(<<"custom_sip_headers">>, Data, wh_json:new()),
    JObj = lists:foldl(fun(F, J) -> F(J) end, CustomHeaders, Routines),
    case wh_util:is_empty(JObj) of
        'true' -> 'undefined';
        'false' -> JObj
    end.

-spec get_ignore_early_media(wh_json:object()) -> api_binary().
get_ignore_early_media(Data) ->
    wh_util:to_binary(wh_json:is_true(<<"ignore_early_media">>, Data, <<"false">>)).

-spec get_force_fax(whapps_call:call()) -> 'undefined' | boolean().
get_force_fax(Call) ->
    case cf_endpoint:get(Call) of
        {'ok', JObj} -> wh_json:is_true([<<"media">>, <<"fax_option">>], JObj);
        {'error', _} -> 'undefined'
    end.

-spec get_flags(wh_json:object(), whapps_call:call()) -> 'undefined' | ne_binaries().
get_flags(Data, Call) ->
    Routines = [fun get_endpoint_flags/3
                ,fun get_flow_flags/3
                ,fun get_flow_dynamic_flags/3
                ,fun get_endpoint_dynamic_flags/3
                ,fun get_account_dynamic_flags/3
               ],
    lists:foldl(fun(F, A) -> F(Data, Call, A) end, [], Routines).

-spec get_endpoint_flags(wh_json:object(), whapps_call:call(), ne_binaries()) -> ne_binaries().
get_endpoint_flags(_, Call, Flags) ->
    case cf_endpoint:get(Call) of
        {'error', _} -> Flags;
        {'ok', JObj} ->
            case wh_json:get_value(<<"outbound_flags">>, JObj) of
                'undefined' -> Flags;
                 EndpointFlags -> EndpointFlags ++ Flags
            end
    end.

-spec get_flow_flags(wh_json:object(), whapps_call:call(), ne_binaries()) -> ne_binaries().
get_flow_flags(Data, _, Flags) ->
    case wh_json:get_value(<<"outbound_flags">>, Data) of
        'undefined' -> Flags;
        FlowFlags -> FlowFlags ++ Flags
    end.

-spec get_flow_dynamic_flags(wh_json:object(), whapps_call:call(), ne_binaries()) -> ne_binaries().
get_flow_dynamic_flags(Data, Call, Flags) ->
    case wh_json:get_value(<<"dynamic_flags">>, Data) of
        'undefined' -> Flags;
        DynamicFlags -> process_dynamic_flags(DynamicFlags, Flags, Call)
    end.

-spec get_endpoint_dynamic_flags(wh_json:object(), whapps_call:call(), ne_binaries()) -> ne_binaries().
get_endpoint_dynamic_flags(_, Call, Flags) ->
    case cf_endpoint:get(Call) of
        {'error', _} -> Flags;
        {'ok', JObj} ->
            case wh_json:get_value(<<"dynamic_flags">>, JObj) of
                'undefined' -> Flags;
                 DynamicFlags ->
                    process_dynamic_flags(DynamicFlags, Flags, Call)
            end
    end.

-spec get_account_dynamic_flags(wh_json:object(), whapps_call:call(), ne_binaries()) -> ne_binaries().
get_account_dynamic_flags(_, Call, Flags) ->
    DynamicFlags = whapps_account_config:get(whapps_call:account_id(Call)
                                             ,<<"callflow">>
                                             ,<<"dynamic_flags">>
                                             ,[]
                                            ),
    process_dynamic_flags(DynamicFlags, Flags, Call).

-spec process_dynamic_flags(ne_binaries(), ne_binaries(), whapps_call:call()) -> ne_binaries().
process_dynamic_flags([], Flags, _) -> Flags;
process_dynamic_flags([DynamicFlag|DynamicFlags], Flags, Call) ->
    case is_flag_exported(DynamicFlag) of
        'false' -> process_dynamic_flags(DynamicFlags, Flags, Call);
        'true' ->
            Fun = wh_util:to_atom(DynamicFlag),
            process_dynamic_flags(DynamicFlags, [whapps_call:Fun(Call)|Flags], Call)
    end.

-spec is_flag_exported(ne_binary()) -> boolean().
is_flag_exported(Flag) ->
    is_flag_exported(Flag, whapps_call:module_info('exports')).

is_flag_exported(_, []) -> 'false';
is_flag_exported(Flag, [{F, 1}|Funs]) ->
    case wh_util:to_binary(F) =:= Flag of
        'true' -> 'true';
        'false' -> is_flag_exported(Flag, Funs)
    end;
is_flag_exported(Flag, [_|Funs]) -> is_flag_exported(Flag, Funs).

-spec get_diversions(whapps_call:call()) -> 'undefined' | wh_json:object().
get_diversions(Call) ->
    case wh_json:get_value(<<"Diversions">>, whapps_call:custom_channel_vars(Call)) of
        'undefined' -> 'undefined';
        [] -> 'undefined';
        Diversions ->  Diversions
    end.

-spec get_inception(whapps_call:call()) -> api_binary().
get_inception(Call) ->
    wh_json:get_value(<<"Inception">>, whapps_call:custom_channel_vars(Call)).


stop_recording(Call) ->
    Format = recording_format(),
    MediaName = get_media_name(whapps_call:call_id(Call), Format),

    _ = whapps_call_command:record_call([{<<"Media-Name">>, MediaName}], <<"stop">>, Call),
    lager:debug("recording of ~s stopped", [MediaName]),

    save_recording(Call, MediaName, Format).

start_recording(Call) ->
    Format = recording_format(),
    MediaName = get_media_name(whapps_call:call_id(Call), Format),
    lager:debug("recording of ~s started", [MediaName]),
    whapps_call_command:record_call([{<<"Media-Name">>, MediaName}], <<"start">>, Call).

recording_format() ->
    whapps_config:get(<<"callflow">>, [<<"call_recording">>, <<"extension">>], <<"mp3">>).

save_recording(Call, MediaName, Format) ->
    {'ok', MediaJObj} = store_recording_meta(Call, MediaName, Format),
    lager:debug("stored meta: ~p", [MediaJObj]),

    StoreUrl = wapi_dialplan:local_store_url(Call, MediaJObj),
    lager:debug("store url: ~s", [StoreUrl]),

    whapps_call_command:store(MediaName, StoreUrl, Call),
    wh_json:get_value(<<"_id">>, MediaJObj).

-spec store_recording_meta(whapps_call:call(), ne_binary(), ne_binary()) ->
                                  {'ok', wh_json:object()} |
                                  {'error', any()}.
store_recording_meta(Call, MediaName, Ext) ->
    AcctDb = whapps_call:account_db(Call),
    CallId = whapps_call:call_id(Call),

    MediaDoc = wh_doc:update_pvt_parameters(
                 wh_json:from_list(
                   [{<<"name">>, MediaName}
                    ,{<<"description">>, <<"broadcast recording ", MediaName/binary>>}
                    ,{<<"content_type">>, ext_to_mime(Ext)}
                    ,{<<"media_type">>, Ext}
                    ,{<<"media_source">>, <<"recorded">>}
                    ,{<<"source_type">>, wh_util:to_binary(?MODULE)}
                    ,{<<"pvt_type">>, <<"broadcast_recording">>}
                    ,{<<"from">>, whapps_call:from(Call)}
                    ,{<<"to">>, whapps_call:to(Call)}
                    ,{<<"caller_id_number">>, whapps_call:caller_id_number(Call)}
                    ,{<<"caller_id_name">>, whapps_call:caller_id_name(Call)}
                    ,{<<"call_id">>, CallId}
                    ,{<<"_id">>, get_recording_doc_id(CallId)}
                   ])
                 ,AcctDb
                ),
    couch_mgr:save_doc(AcctDb, MediaDoc).

ext_to_mime(<<"wav">>) -> <<"audio/x-wav">>;
ext_to_mime(_) -> <<"audio/mp3">>.

get_recording_doc_id(CallId) -> <<"call_recording_", CallId/binary>>.

-spec get_media_name(ne_binary(), ne_binary()) -> ne_binary().
get_media_name(CallId, Ext) ->
    <<(get_recording_doc_id(CallId))/binary, ".", Ext/binary>>.


create_call(Account, User, Task, Number) ->
    AccountId = wh_json:get_value(<<"_id">>, Account),
    UserId = wh_json:get_value(<<"_id">>, User),

    AccountDb = wh_util:format_account_id(AccountId, 'encoded'),
    Realm = wh_json:get_ne_value(<<"realm">>, Account),

    C = whapps_call:exec([
            fun(C) -> whapps_call:set_authorizing_type(<<"user">>, C) end
            ,fun(C) -> whapps_call:set_authorizing_id(UserId, C) end
            ,fun(C) -> whapps_call:set_request(<<Number/binary, <<"@">>/binary, Realm/binary>>, C) end
            ,fun(C) -> whapps_call:set_to(<<Number/binary, <<"@">>/binary, Realm/binary>>, C) end
            ,fun(C) -> whapps_call:set_account_db(AccountDb, C) end
            ,fun(C) -> whapps_call:set_account_id(AccountId, C) end
            ,fun(C) -> set_cid_name(Account, User, Task, C) end
            ,fun(C) -> set_cid_number(Account, User, Task, C) end
            ,fun(C) -> whapps_call:set_callee_id_name(Number, C) end
            ,fun(C) -> whapps_call:set_callee_id_number(Number, C) end
            ,fun(C) -> whapps_call:set_owner_id(UserId, C) end]
            ,whapps_call:new()),
    whapps_call:set_from(<<(whapps_call:caller_id_number(C))/binary, <<"@">>/binary, Realm/binary>>, C).

set_cid_name(Account, User, Task, Call) ->
    case wh_json:get_value(<<"cid_name">>, Task) of
        'undefined' -> maybe_set_user_cid_name(Account, User, Task, Call);
        CIDName -> whapps_call:set_caller_id_name(CIDName, Call)
    end.

maybe_set_user_cid_name(Account, User, Task, Call) ->
    case wh_json:get_value([<<"caller_id">>, <<"external">>, <<"name">>], User) of
        'undefined' -> maybe_set_account_cid_name(Account, User, Task, Call);
        CIDName -> whapps_call:set_caller_id_name(CIDName, Call)
    end.

maybe_set_account_cid_name(Account, _User, _Task, Call) ->
    case wh_json:get_value([<<"caller_id">>, <<"external">>, <<"name">>], Account) of
        'undefined' -> Call;
        CIDName -> whapps_call:set_caller_id_name(CIDName, Call)
    end.


set_cid_number(Account, User, Task, Call) ->
    case wh_json:get_value(<<"cid_number">>, Task) of
        'undefined' -> maybe_set_user_cid_number(Account, User, Task, Call);
        CIDNumber -> whapps_call:set_caller_id_number(CIDNumber, Call)
    end.

maybe_set_user_cid_number(Account, User, Task, Call) ->
    case wh_json:get_value([<<"caller_id">>, <<"external">>, <<"number">>], User) of
        'undefined' -> maybe_set_account_cid_number(Account, User, Task, Call);
        CIDNumber -> whapps_call:set_caller_id_number(CIDNumber, Call)
    end.

maybe_set_account_cid_number(Account, _User, _Task, Call) ->
    case wh_json:get_value([<<"caller_id">>, <<"external">>, <<"number">>], Account) of
        'undefined' -> Call;
        CIDNumber -> whapps_call:set_caller_id_number(CIDNumber, Call)
    end.

