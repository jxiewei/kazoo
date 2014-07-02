-module(ob_conference).

-behaviour(gen_listener).

-include_lib("whistle/include/wh_databases.hrl").
-include("conference.hrl").

%%API
-export([start_link/3]).

%%gen_server callbacks
-export([init/1
        ,handle_event/2
        ,handle_call/3
        ,handle_info/2
        ,handle_cast/2
        ,terminate/2
        ,code_change/3]).

-define('SERVER', ?MODULE).

-define(RESPONDERS, []).
-define(QUEUE_NAME, <<>>).
-define(QUEUE_OPTIONS, []).
-define(CONSUME_OPTIONS, []).
-define(DEVICES_VIEW, <<"devices/listing_by_owner">>).

-record(ob_conf_req, {account_id :: binary()
                      ,userid :: binary()
                      ,conferenceid :: binary()
                      ,account :: wh_json:new() %Doc of request account
                      ,user :: wh_json:new() %Doc of request user
                      ,conference :: whapps_conference:conference()
                      ,myq :: binary()
                      ,de
                      ,calls=dict:new()
                      ,node=node()
                      ,host
                      ,server :: pid()
                     }).


start_link(AccountId, UserId, ConferenceId) ->
    Bindings = [{'self', []}],
    lager:debug("jerry -- starting ob_conference(~p, ~p, ~p)~n", [AccountId, UserId, ConferenceId]),
    gen_listener:start_link(?MODULE, [{'responders', ?RESPONDERS}
                                      ,{'bindings', Bindings}
                                      ,{'queue_name', ?QUEUE_NAME}
                                      ,{'queue_options', ?QUEUE_OPTIONS}
                                      ,{'consume_options', ?CONSUME_OPTIONS}
                                     ], [AccountId, UserId, ConferenceId]).

channel_answered(UUID) ->
    case whapps_util:amqp_pool_collect([{<<"Fields">>, [<<"Answered">>]}
                                        ,{<<"Call-ID">>, UUID}
                                        |wh_api:default_headers(?APP_NAME, ?APP_VERSION)
                                       ]
                                       ,fun wapi_call:publish_query_channels_req/1
                                       %,fun wapi_call:query_channels_resp_v/1
                                       ,{'ecallmgr', 'true'}
                                       ,20000)
    of
    {'ok', [Resp|_]} ->
        {'ok', wh_json:get_value([<<"Channels">>, UUID, <<"Answered">>], Resp)};
    _R ->
        lager:debug("jerry -- failed to get channel information ~p", [_R]),
        {'error'}
    end.

channel_control_queue(UUID) ->
    Req = [{<<"Call-ID">>, wh_util:to_binary(UUID)}
           | wh_api:default_headers(<<"shell">>, <<"0">>)
          ],
    case whapps_util:amqp_pool_request(Req
                                       ,fun wapi_call:publish_channel_status_req/1
                                       ,fun wapi_call:channel_status_resp_v/1
                                      )
    of
        {'ok', Resp} ->
            lager:debug("jerry -- channel status ~p~n", [Resp]),
            wh_json:get_value(<<"Control-Queue">>, Resp);
        {'error', _E} ->
            lager:debug("jerry -- failed to get status of '~s': '~p'", [UUID, _E]),
            'undefined'
    end.

handle_call(_Request, _, P) ->
    {'reply', {'error', 'unimplemented'}, P}.

handle_info(_Msg, ObConfReq) ->
    lager:debug("unhandled message: ~p", [_Msg]),
    {'noreply', ObConfReq}.

handle_cast({'init'}, ObConfReq) ->
    Conference = ObConfReq#ob_conf_req.conference,
    Moderators = wh_json:get_value([<<"moderator">>, <<"numbers">>], Conference),
    Members = wh_json:get_value([<<"member">>, <<"numbers">>], Conference),
    Server = ObConfReq#ob_conf_req.server,

    DE = wh_json:from_list([{<<"Server-ID">>, ObConfReq#ob_conf_req.myq}
                           ,{<<"Conference-Doc">>, ObConfReq#ob_conf_req.conference}]),
    S = ObConfReq#ob_conf_req{de=DE},

    Props = [{'restrict_to', [<<"CHANNEL_BRIDGE">>]}],
    gen_listener:add_binding(Server, 'call', Props),

    lists:foreach(fun(Number) -> 
                spawn(fun() -> originate_participant(moderator, wh_util:to_binary(Number), Server, S) end) end, Moderators),
    lists:foreach(fun(Number) -> 
                spawn(fun() -> originate_participant(member, wh_util:to_binary(Number), Server, S) end) end, Members),

    {'noreply', S};

handle_cast({'originate_success', OID, Call}, ObConfReq) ->
    Calls = ObConfReq#ob_conf_req.calls,
    lager:debug("jerry -- originate succeed, add it(oid ~p) to dict", [OID]),
    {'noreply', ObConfReq#ob_conf_req{calls=dict:store(OID, Call, Calls)}};

handle_cast({'update_callid', OID, CallId}, ObConfReq) ->
    Calls = ObConfReq#ob_conf_req.calls,
    case dict:find(OID, ObConfReq#ob_conf_req.calls) of
    {'ok', Call} ->
        {'noreply', ObConfReq#ob_conf_req{calls=dict:store(OID, whapps_call:set_call_id(CallId, Call), Calls)}};
    _ -> {'noreply', ObConfReq}
    end;

handle_cast({'answered', OldCall}, ObConfReq) ->
    lager:debug("jerry -- join (call ~p) to conference~n", [OldCall]),
    CallId = whapps_call:call_id(OldCall),
    put('callid', CallId),

    CtrlQ = channel_control_queue(CallId),
    Updaters = [fun(C) -> whapps_call:set_control_queue(CtrlQ, C) end,
                fun(C) -> whapps_call:set_controller_queue(ObConfReq#ob_conf_req.myq, C) end ],
    Call = lists:foldr(fun(F, C) -> F(C) end, OldCall, Updaters),

    lager:debug("jerry -- starting conf_participant(~p)~n", [Call]),


    spawn(fun() ->
        whapps_call_command:prompt(<<"conf-welcome">>, Call),
        {'ok', Srv} = conf_participant_sup:start_participant(Call),
        conf_participant:set_discovery_event(ObConfReq#ob_conf_req.de, Srv),
        %conf_participant:consume_call_events(Srv),
        conf_discovery_req:search_for_conference(
                whapps_conference:from_conference_doc(ObConfReq#ob_conf_req.conference), 
                Call, Srv)
        end),


    %%FIXME: store Call to calls
    {'noreply', ObConfReq};

handle_cast({'channel_destroyed', OID}, ObConfReq) ->
    Calls = dict:erase(OID, ObConfReq#ob_conf_req.calls),
    case dict:size(Calls) of
    0 -> 
        lager:debug("jerry -- all channels destroyed, destroy conference"),
        gen_listener:cast(ObConfReq#ob_conf_req.server, {'conference_destroyed'});
    _ -> 'ok'
    end,
    {'noreply', ObConfReq#ob_conf_req{calls=Calls}};

handle_cast({'conference_destroyed'}, ObConfReq) ->
    {'stop', {'shutdown', 'hangup'}, ObConfReq};

handle_cast({'gen_listener',{'is_consuming',_IsConsuming}}, State) ->
    {'noreply', State};
handle_cast({'gen_listener',{'created_queue',_QueueName}}, State) ->
    gen_listener:cast(State#ob_conf_req.server, {'init'}),
    {'noreply', State#ob_conf_req{myq=_QueueName}};
handle_cast(_Cast, State) ->
    lager:debug("jerry -- unhandled cast: ~p", [_Cast]),
    {'noreply', State}.

handle_event(JObj, ObConfReq) ->
    case whapps_util:get_event_type(JObj) of
        {<<"call_event">>, <<"CHANNEL_BRIDGE">>} ->
            lager:debug("jerry -- received channel bridge event ~p~n", [JObj]),
            OID = wh_json:get_value([<<"Custom-Channel-Vars">>, <<"OBConf-Originate-ID">>], JObj),
            OtherLegCallId = wh_json:get_binary_value(<<"Other-Leg-Call-ID">>, JObj),
            lager:debug("jerry -- received channel bridge event oid ~p, other_leg_callid ~p~n", [OID, OtherLegCallId]),
            case dict:find(OID, ObConfReq#ob_conf_req.calls) of
            {'ok', Call} ->
                'ok' = gen_listener:cast(ObConfReq#ob_conf_req.server, {'update_callid', OID, OtherLegCallId}),
                lager:debug("jerry -- call found, ~p", [Call]),
                {'ok', Answered} = channel_answered(OtherLegCallId),
                lager:debug("jerry -- channel answered ~p~n", [Answered]),
                case Answered of
                'true' ->
                    Props = [{'callid', OtherLegCallId},{'restrict_to', [<<"CHANNEL_DESTROY">>]}],
                    gen_listener:add_binding(ObConfReq#ob_conf_req.server, 'call', Props),
                    'ok' = gen_listener:cast(ObConfReq#ob_conf_req.server, {'answered', whapps_call:set_call_id(OtherLegCallId, Call)}),
                    {'reply', []};
                 _ -> 
                    Props = [{'callid', OtherLegCallId},{'restrict_to', [<<"CHANNEL_ANSWER">>, <<"CHANNEL_DESTROY">>]}],
                    gen_listener:add_binding(ObConfReq#ob_conf_req.server, 'call', Props),
                    {'reply', []}
                end;
            _ ->
                lager:debug("OID ~p not found", [OID]),
                {'reply', []}
            end;
        {<<"call_event">>, <<"CHANNEL_ANSWER">>} ->
            lager:debug("jerry -- received channel answer event ~p~n", [JObj]),
            CallId = wh_json:get_value(<<"Call-ID">>, JObj),
            Dict = dict:filter(fun(_, Value) -> whapps_call:call_id(Value) =:= CallId end, ObConfReq#ob_conf_req.calls),
            [{_, Call}|_] = dict:to_list(Dict),
            lager:debug("jerry -- call found"),
            'ok' = gen_listener:cast(ObConfReq#ob_conf_req.server, {'answered', Call}),
            {'reply', []};
        {<<"call_event">>, <<"CHANNEL_DESTROY">>} ->
            lager:debug("jerry -- received channel destroy event ~p~n", [JObj]),
            CallId = wh_json:get_value(<<"Call-ID">>, JObj),
            Dict = dict:filter(fun(_, Value) -> whapps_call:call_id(Value) =:= CallId end, ObConfReq#ob_conf_req.calls),
            [OID|_] = dict:fetch_keys(Dict),
            lager:debug("jerry -- call found, OID ~p~n", [OID]),
            
            gen_listener:cast(ObConfReq#ob_conf_req.server, {'channel_destroyed', OID});
        {_Else, _Info} ->
            lager:debug("jerry -- received channel event ~p~n", [JObj]),
            {'reply', []}
    end.

terminate(_Reason, _ObConfReq) ->
    lager:debug("ob_conference execution has been stopped: ~p", [_Reason]).

originate_participant(_Type, Number, Srv,
                        #ob_conf_req{account_id=AccountId
                                ,account=Account
                                ,userid=UserId
                                ,user=User
                                ,host=Host
                                ,node=FSNode
                                }) ->

    AccountDb = wh_util:format_account_id(AccountId, 'encoded'),
    ViewOptions = [{'key', UserId}],
    case couch_mgr:get_results(AccountDb, ?DEVICES_VIEW, ViewOptions) of
        {'ok', JObjs} ->
            SipDevices = lists:filter(fun(Obj) -> 
                                        {'ok', Dev} = couch_mgr:open_cache_doc(AccountDb, wh_json:get_value([<<"value">>, <<"id">>], Obj)),
                                        wh_json:get_value(<<"device_type">>, Dev) =:= <<"softphone">>
                                      end, JObjs),
            DeviceId = wh_json:get_value(<<"id">>, lists:nth(1, SipDevices));
        {'error', _R} ->
            DeviceId = 'undefined',
            lager:debug("softphone device owned by ~p not found~n", [UserId])
    end,

    {'ok', RequestDevice} = couch_mgr:open_cache_doc(AccountDb, DeviceId),
    CallerId = wh_json:get_value([<<"caller_id">>, <<"external">>], User),
    Realm = wh_json:get_ne_value(<<"realm">>, Account),
    FromUser = wh_json:get_value([<<"sip">>, <<"username">>], RequestDevice),
    MsgId = wh_util:rand_hex_binary(16),


    CCVs = [{<<"Account-ID">>, AccountId}  
            ,{<<"Retain-CID">>, <<"true">>}
            ,{<<"Inherit-Codec">>, <<"false">>}
            ,{<<"Authorizing-Type">>, <<"device">>}
            ,{<<"Authorizing-ID">>, DeviceId}                                                                                                                                    
            ,{<<"OBConf-Originate-ID">>, MsgId}
           ],

    Endpoint = [{<<"Invite-Format">>, <<"route">>}
                ,{<<"Route">>,  <<"loopback/", Number/binary, "/context_2">>}                                                                                                    
                ,{<<"To-DID">>, Number}        
                ,{<<"To-Realm">>, Realm}       
                ,{<<"Custom-Channel-Vars">>, wh_json:from_list(CCVs)}                                                                                                            
               ],

    Call = whapps_call:exec([
               fun(C) -> whapps_call:set_authorizing_type(<<"device">>, C) end
               ,fun(C) -> whapps_call:set_authorizing_id(DeviceId, C) end
               ,fun(C) -> whapps_call:set_request(<<FromUser/binary, <<"@">>/binary, Realm/binary>>, C) end
               ,fun(C) -> whapps_call:set_account_db(AccountDb, C) end
               ,fun(C) -> whapps_call:set_account_id(AccountId, C) end
               ,fun(C) -> whapps_call:set_owner_id(UserId, C) end
               ,fun(C) -> whapps_call:set_switch_nodename(FSNode, C) end
               ,fun(C) -> whapps_call:set_switch_hostname(Host, C) end]
               ,whapps_call:new()),

    Request = props:filter_undefined(
                 [{<<"Application-Name">>, <<"noop">>}
                 ,{<<"Originate-Immediate">>, 'true'}
                 ,{<<"Msg-ID">>, MsgId}         
                 ,{<<"Endpoints">>, [wh_json:from_list(Endpoint)]}
                 ,{<<"Outbound-Caller-ID-Name">>, wh_json:get_value(<<"name">>, CallerId)}
                 ,{<<"Outbound-Caller-ID-Number">>, wh_json:get_value(<<"number">>, CallerId)}                                                                                   
                 ,{<<"Outbound-Callee-ID-Name">>, Number}
                 ,{<<"Outbound-Callee-ID-Number">>, Number}
                 ,{<<"Request">>,<<FromUser/binary, <<"@">>/binary, Realm/binary>>} 
                 ,{<<"From">>, <<FromUser/binary, <<"@">>/binary, Realm/binary>>}
                 ,{<<"Dial-Endpoint-Method">>, <<"single">>}
                 ,{<<"Continue-On-Fail">>, 'true'}
                 ,{<<"Custom-Channel-Vars">>, wh_json:from_list(CCVs)}
                 ,{<<"Export-Custom-Channel-Vars">>, [<<"Account-ID">>, <<"Retain-CID">>, <<"Authorizing-ID">>, <<"Authorizing-Type">>]}                                         
                 | wh_api:default_headers(<<"resource">>, <<"originate_req">>, ?APP_NAME, ?APP_VERSION)                                                                          
                ]),

    wapi_resource:publish_originate_req(Request),
    gen_listener:cast(Srv, {'originate_success', MsgId, Call}).


code_change(_OldVsn, ObConfReq, _Extra) ->
    {'ok', ObConfReq}.

init([AccountId, UserId, ConferenceId]) ->
    process_flag('trap_exit', 'true'),
    AccountDb = wh_util:format_account_id(AccountId, 'encoded'),
    {'ok', AccountDoc} = couch_mgr:open_cache_doc(?WH_ACCOUNTS_DB, AccountId),
    {'ok', UserDoc} = couch_mgr:open_cache_doc(AccountDb, UserId),
    {'ok', ConferenceDoc} = couch_mgr:open_cache_doc(AccountDb, ConferenceId),


    N = wh_util:to_binary(node()),
    [_, Host] = binary:split(N, <<"@">>),
    FSNode = wh_util:to_atom(<<"freeswitch@", Host/binary>>, 'true'),
    {'ok', #ob_conf_req{account_id=AccountId
                       ,userid=UserId
                       ,conferenceid=ConferenceId
                       ,account=AccountDoc
                       ,user=UserDoc
                       ,conference=ConferenceDoc
                       ,host=Host
                       ,node=FSNode
                       ,server=self()}}.
