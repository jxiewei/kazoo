-module(outbound_call).

-behaviour(gen_listener).

-include_lib("whistle/include/wh_databases.hrl").
-include("outbound.hrl").

%%API
-export([start_link/1
        ,start_outbound_call/1
        ]).

%%gen_server callbacks
-export([init/1
        ,handle_event/2
        ,handle_call/3
        ,handle_info/2
        ,handle_cast/2
        ,terminate/2
        ,code_change/3]).

-define('SERVER', ?MODULE).
-define(DEFAULT_TIMEOUT, 3).

-define(RESPONDERS, []).
-define(QUEUE_NAME, <<>>).
-define(QUEUE_OPTIONS, []).
-define(CONSUME_OPTIONS, []).

-record(state, {outboundid, mycall, callerpid}).

%% API

start_link(Call) ->
    Bindings = [{'self', []}],
    gen_listener:start_link(?MODULE, [{'responders', ?RESPONDERS}
                                      ,{'bindings', Bindings}
                                      ,{'queue_name', ?QUEUE_NAME}
                                      ,{'queue_options', ?QUEUE_OPTIONS}
                                      ,{'consume_options', ?CONSUME_OPTIONS}
                                     ], [Call]).

wait_outbound_call(Timeout) ->
    Start = os:timestamp(),
    receive
        {'outbound_call_completed', Ret} -> Ret;
        _ -> 
            wait_outbound_call(wh_util:decr_timeout(Timeout, Start))
    after
        Timeout ->
            {'error', 'timeout'}
    end.
            
start_outbound_call(Call) ->
    outbound_call_sup:start_outbound_call(Call, self()),
    wait_outbound_call(?DEFAULT_TIMEOUT).

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
            lager:debug("channel status ~p", [Resp]),
            wh_json:get_value(<<"Control-Queue">>, Resp);
        {'error', _E} ->
            lager:error("failed to get channel status of '~s': '~p'", [UUID, _E]),
            'undefined'
    end.

%% Callbacks
handle_info(_Msg, State) ->
    lager:info("unhandled message: ~p", [_Msg]),
    {'noreply', State}.

handle_cast('originate_outbound_call', State={outboundid=OutboundId, mycall=Call}) ->
    AccountId = whapps_call:account_id(Call),

    CCVs = [{<<"Account-ID">>, AccountId}
            ,{<<"Retain-CID">>, <<"true">>}
            ,{<<"Inherit-Codec">>, <<"false">>}
            ,{<<"Authorizing-Type">>, whapps_call:authorizing_type(Call)}
            ,{<<"Authorizing-ID">>, whapps_call:authorizing_id(Call)}
            ,{<<"OutBound-ID">>, OutboundId}
           ],

    Number = whapps_call:callee_id_number(Call),
    Endpoint = [{<<"Invite-Format">>, <<"route">>}
                ,{<<"Route">>,  <<"loopback/", Number/binary, "/context_2">>}
                ,{<<"To-DID">>, whapps_call:callee_id_number(Call)}
                ,{<<"To-Realm">>, whapps_call:request_realm(Call)}
                ,{<<"Custom-Channel-Vars">>, wh_json:from_list(CCVs)}
               ],

    Request = props:filter_undefined(
                 [{<<"Application-Name">>, <<"park">>}
                 ,{<<"Originate-Immediate">>, 'true'}
                 ,{<<"Msg-ID">>, OutboundId}         
                 ,{<<"Endpoints">>, [wh_json:from_list(Endpoint)]}
                 ,{<<"Outbound-Caller-ID-Name">>, whapps_call:caller_id_name(Call)}
                 ,{<<"Outbound-Caller-ID-Number">>, whapps_call:caller_id_number(Call)}
                 ,{<<"Outbound-Callee-ID-Name">>, whapps_call:callee_id_name(Call)}
                 ,{<<"Outbound-Callee-ID-Number">>, whapps_call:callee_id_number(Call)}
                 ,{<<"Request">>, whapps_call:request(Call)}
                 ,{<<"From">>, whapps_call:from(Call)}
                 ,{<<"Dial-Endpoint-Method">>, <<"single">>}
                 ,{<<"Continue-On-Fail">>, 'false'}
                 ,{<<"Custom-Channel-Vars">>, wh_json:from_list(CCVs)}
                 ,{<<"Export-Custom-Channel-Vars">>, [<<"Account-ID">>, <<"Retain-CID">>
                                                     ,<<"Authorizing-ID">>, <<"Authorizing-Type">>
                                                     ,<<"OutBound-ID">>]}                                         
                 | wh_api:default_headers(<<"resource">>, <<"originate_req">>, ?APP_NAME, ?APP_VERSION)                                                                          
                ]),

    wapi_resource:publish_originate_req(Request),
    {'noreply', State};

handle_cast({'channel_bridged', JObj}, State) ->
    OutboundId = wh_json:get_value([<<"Custom-Channel-Vars">>, <<"OutBound-ID">>], JObj),
    OtherLegCallId = wh_json:get_binary_value(<<"Other-Leg-Call-ID">>, JObj),
    lager:debug("received channel bridge event for outboundid ~p, other_leg_callid ~p", [OutboundId, OtherLegCallId]),
    
    CtrlQ = channel_control_queue(OtherLegCallId),
    Call = whapps_call:exec([
                    fun(C) -> whapps_call:set_call_id(OtherLegCallId, C) end
                    ,fun(C) -> whapps_call:set_control_queue(CtrlQ, C) end]
                    ,State#state.mycall),
    gen_listener:cast(State#state.callerpid, {'outbound_call_completed', {'ok', Call}}),
    {'stop', {'shutdown', 'successful'}, State};

handle_cast({'gen_listener',{'is_consuming',_IsConsuming}}, State) ->
    {'noreply', State};

handle_cast({'gen_listener',{'created_queue',_QueueName}}, State) ->
    gen_listener:cast(self(), 'originate_outbound_call'),
    {'noreply', State};

handle_cast(_Cast, State) ->
    lager:debug("unhandled cast: ~p", [_Cast]),
    {'noreply', State}.

handle_call(_Request, _, P) ->
    {'reply', {'error', 'unimplemented'}, P}.

handle_event(JObj, _State) ->
    lager:debug("unhandled event ~p", [JObj]),
    {'reply', []}.

terminate(_Reason, _ObConf) ->
    lager:debug("outbound_call execution has been stopped: ~p", [_Reason]).

code_change(_OldVsn, ObConf, _Extra) ->
    {'ok', ObConf}.

init([Call, CallerPid]) ->
    process_flag('trap_exit', 'true'),
    OutboundId = wh_util:rand_hex_binary(16),
    Server = outbound_call_manager:pid(),
    gen_listener:cast(Server, {'outbound_call_started', OutboundId, Call}),
    {'ok', #state{outboundid=OutboundId, mycall=Call, callerpid=CallerPid}}.
