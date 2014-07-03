-module(ob_conference).

-behaviour(gen_listener).

-include_lib("whistle/include/wh_databases.hrl").
-include("conference.hrl").

%%API
-export([start_link/3
        ,kick/2
        ,join/2]).

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

-record(ob_conf_participant, {pid, number, conf_participant_pid}).

-record(ob_conf, {account_id :: binary()
                      ,userid :: binary()
                      ,conferenceid :: binary()
                      ,account :: wh_json:new() %Doc of request account
                      ,user :: wh_json:new() %Doc of request user
                      ,conference :: whapps_conference:conference()
                      ,ob_participants
                      ,node=node()
                      ,host
                      ,server
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


kick(ConferenceId, Number) ->
    case ob_conferences:get_server(ConferenceId) of 
    {'ok', Srv} ->
        lager:debug("jerry -- ob conference is at ~p", [Srv]),
        gen_listener:call(Srv, {'kick', Number});
    _ ->
        lager:debug("jerry -- ob conference server for ~p not found", [ConferenceId]),
        'error'
    end.

join(ConferenceId, Number) ->
    case ob_conferences:get_server(ConferenceId) of
    {'ok', Srv} ->
        lager:debug("jerry -- ob conference is at ~p", [Srv]),
        gen_listener:call(Srv, {'join', Number}),
        'ok';
    _ ->
        lager:debug("jerry -- ob conference server for ~p not found", [ConferenceId]),
        'error'
    end.

handle_info(_Msg, ObConfReq) ->
    lager:debug("unhandled message: ~p", [_Msg]),
    {'noreply', ObConfReq}.

handle_cast('init', ObConf) ->
    Conference = ObConf#ob_conf.conference,
    Moderators = wh_json:get_value([<<"moderator">>, <<"numbers">>], Conference),
    Members = wh_json:get_value([<<"member">>, <<"numbers">>], Conference),
    Props = [{'restrict_to', [<<"CHANNEL_BRIDGE">>]}],

    gen_listener:add_binding(self(), 'call', Props),
    [gen_listener:cast(self(), {'originate_participant', moderator, wh_util:to_binary(N)}) || N <- Moderators],
    [gen_listener:cast(self(), {'originate_participant', member, wh_util:to_binary(N)}) || N <- Members],
    ob_conferences:register_server(wh_json:get_value(<<"_id">>, Conference), self()),

    {'noreply', ObConf};

handle_cast({'originate_participant', _Type, Number},
                        #ob_conf{account_id=AccountId
                                ,account=Account
                                ,userid=UserId
                                ,user=User
                                ,host=Host
                                ,node=FSNode
                                }=ObConf) ->

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
               ,fun(C) -> whapps_call:set_to(<<Number/binary, <<"@">>/binary, Realm/binary>>, C) end
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
    {'ok', Pid} = ob_conf_participant_sup:start_ob_conf_participant(self(), ObConf#ob_conf.conference, MsgId, Call),
    ObParticipant = #ob_conf_participant{pid = Pid, number = Number},
    {'noreply', ObConf#ob_conf{ob_participants=dict:store(MsgId, ObParticipant, ObConf#ob_conf.ob_participants)}};


handle_cast({'conf_participant_started', OID, Pid}, ObConf) ->
    lager:debug("jerry -- conf_participant for oid ~p started, pid ~p", [OID, Pid]),
    P = ObConf#ob_conf.ob_participants,
    {'ok', OP} = dict:find(OID, P),
    NewOP = OP#ob_conf_participant{conf_participant_pid=Pid},
    {'noreply', ObConf#ob_conf{ob_participants=dict:store(OID, NewOP, ObConf#ob_conf.ob_participants)}};

handle_cast({'channel_destroyed', OID}, ObConf) ->
    P = ObConf#ob_conf.ob_participants,
    NP =  dict:erase(OID, P),
    case dict:size(NP) of
    0 -> gen_listener:cast(self(), 'conference_destroyed');
    _ -> 'ok'
    end,
    {'noreply', ObConf#ob_conf{ob_participants=NP}};

handle_cast('conference_destroyed', ObConf) ->
    ob_conferences:unregister_server(wh_json:get_value(<<"_id">>, ObConf#ob_conf.conference)),
    {'stop', {'shutdown', 'hangup'}, ObConf};

handle_cast({'channel_bridged', JObj}, ObConf) ->
    OID = wh_json:get_value([<<"Custom-Channel-Vars">>, <<"OBConf-Originate-ID">>], JObj),
    OtherLegCallId = wh_json:get_binary_value(<<"Other-Leg-Call-ID">>, JObj),
    lager:debug("jerry -- received channel bridge event oid ~p, other_leg_callid ~p~n", [OID, OtherLegCallId]),
    case dict:find(OID, ObConf#ob_conf.ob_participants) of
    {'ok', #ob_conf_participant{pid=Pid}} ->
        'ok' = gen_listener:cast(Pid, {'set_callid', OtherLegCallId});
    _ ->
        lager:debug("OID ~p not found", [OID])
    end,
    {'noreply', ObConf};

handle_cast({'gen_listener',{'is_consuming',_IsConsuming}}, ObConf) ->
    {'noreply', ObConf};

handle_cast({'gen_listener',{'created_queue',_QueueName}}, ObConf) ->
    gen_listener:cast(self(), 'init'),
    {'noreply', ObConf};

handle_cast(_Cast, ObConf) ->
    lager:debug("jerry -- unhandled cast: ~p", [_Cast]),
    {'noreply', ObConf}.

handle_call({'kick', Number}, _From, ObConf) ->
    lager:debug("jerry -- kicking ~p out", [Number]),
    Dict = dict:filter(fun(_, V) -> Number =:= V#ob_conf_participant.number end, ObConf#ob_conf.ob_participants),
    case dict:size(Dict) of
    0 -> {'reply', {'error', 'not_found'}, ObConf};
    _ -> 
        [{_, OP}|_] = dict:to_list(Dict),
        Pid = OP#ob_conf_participant.conf_participant_pid,
        conf_participant:hangup(Pid),
        {'reply', 'ok', ObConf}
    end;

handle_call({'join', Number}, _From, ObConf) ->
    lager:debug("jerry -- joining ~p into confernce", [Number]),
    gen_listener:cast(self(), {'originate_participant', member, Number}),
    {'reply', 'ok', ObConf};

handle_call(_Request, _, P) ->
    {'reply', {'error', 'unimplemented'}, P}.


handle_event(JObj, ObConf) ->
    case whapps_util:get_event_type(JObj) of
        {<<"call_event">>, <<"CHANNEL_BRIDGE">>} ->
            lager:debug("jerry -- received channel bridge event ~p~n", [JObj]),
            gen_listener:cast(ObConf#ob_conf.server, {'channel_bridged', JObj});
        {_Else, _Info} ->
            lager:debug("jerry -- received channel event ~p~n", [JObj])
    end,
    {'reply', []}.

terminate(_Reason, _ObConf) ->
    lager:debug("ob_conference execution has been stopped: ~p", [_Reason]).


code_change(_OldVsn, ObConf, _Extra) ->
    {'ok', ObConf}.

init([AccountId, UserId, ConferenceId]) ->
    process_flag('trap_exit', 'true'),
    AccountDb = wh_util:format_account_id(AccountId, 'encoded'),
    {'ok', AccountDoc} = couch_mgr:open_cache_doc(?WH_ACCOUNTS_DB, AccountId),
    {'ok', UserDoc} = couch_mgr:open_cache_doc(AccountDb, UserId),
    {'ok', ConferenceDoc} = couch_mgr:open_cache_doc(AccountDb, ConferenceId),


    N = wh_util:to_binary(node()),
    [_, Host] = binary:split(N, <<"@">>),
    FSNode = wh_util:to_atom(<<"freeswitch@", Host/binary>>, 'true'),
    {'ok', #ob_conf{account_id=AccountId
                       ,userid=UserId
                       ,conferenceid=ConferenceId
                       ,account=AccountDoc
                       ,user=UserDoc
                       ,conference=ConferenceDoc
                       ,host=Host
                       ,ob_participants=dict:new()
                       ,server=self()
                       ,node=FSNode}}.
