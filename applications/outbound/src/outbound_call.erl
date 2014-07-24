-module(outbound_call).

-behaviour(gen_listener).

-include_lib("whistle/include/wh_databases.hrl").
-include("outbound.hrl").

%%API
-export([start_link/3
        ,start_outbound_call/1
        ,start_outbound_call/2
        ,set_caller/1
        ,wait_answer/0, wait_answer/1
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
-define(DEFAULT_ORIGINATE_TIMEOUT, 3000).
-define(DEFAULT_ANSWER_TIMEOUT, 30000).

-define(RESPONDERS, []).
-define(QUEUE_NAME, <<>>).
-define(QUEUE_OPTIONS, []).
-define(CONSUME_OPTIONS, []).

-record(state, {outboundid, mycall, myendpoint, callerpid, myq, server}).

%% API

start_link(Endpoint, Call, CallerPid) ->
    Bindings = [{'self', []}],
    gen_listener:start_link(?MODULE, [{'responders', ?RESPONDERS}
                                      ,{'bindings', Bindings}
                                      ,{'queue_name', ?QUEUE_NAME}
                                      ,{'queue_options', ?QUEUE_OPTIONS}
                                      ,{'consume_options', ?CONSUME_OPTIONS}
                                     ], [Endpoint, Call, CallerPid]).

wait_originate(Timeout) ->
    Start = os:timestamp(),
    receive
        {'outbound_call_originated', Ret} -> {'ok', Ret};
        {'outbound_call_originate_failed', Ret} -> {'error', Ret};
        _E ->
            lager:debug("jerry -- received other event ~p", [_E]),
            wait_originate(wh_util:decr_timeout(Timeout, Start))
    after
        Timeout -> {'error', 'timeout'}
    end.

%% TODO: Create a waiting list, add caller to the list when this api invoked.
%% Notify all waiter when channel event occured.
%% TODO: maybe it's better to create a generic waiting mechanism in whapps_call_command?
%% basic idea is to create a process to monitor amqp message for a specified call, 
%% block caller and return when specified event occurs.
wait_answer() ->
    wait_answer(?DEFAULT_ANSWER_TIMEOUT).
wait_answer(Timeout) ->
    Start = os:timestamp(),
    receive
        {'outbound_call_answered', Ret} -> {'ok', Ret};
        {'outbound_call_rejected', Ret} -> {'error', Ret};
        _E -> 
            lager:debug("jerry -- received other event ~p", [_E]),
            wait_answer(wh_util:decr_timeout(Timeout, Start))
    after
        Timeout -> {'error', 'timeout'}
    end.
            
start_outbound_call(Call) ->
    {'ok', Pid} = outbound_call_sup:start_outbound_call('undefined', Call, self()),
    case wait_originate(?DEFAULT_ORIGINATE_TIMEOUT) of
        {'ok', Ret} -> {'ok', Pid, Ret};
        _Return -> _Return
    end.

start_outbound_call(Endpoint, Call) ->
    {'ok', Pid} = outbound_call_sup:start_outbound_call(Endpoint, Call, self()),
    case wait_originate(?DEFAULT_ORIGINATE_TIMEOUT) of
        {'ok', Ret} -> {'ok', Pid, Ret};
        _Return -> _Return
    end.

set_caller(Server) ->
    gen_listener:call(Server, 'set_caller').

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
        lager:notice("failed to get channel information ~p", [_R]),
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

handle_cast('originate_outbound_call', State) ->
    lager:debug("jerry -- originating outbound call"),
    #state{outboundid=OutboundId, mycall=Call, myq=Q} = State,
    AccountId = whapps_call:account_id(Call),

    CCVs = [{<<"Account-ID">>, AccountId}
            ,{<<"Retain-CID">>, <<"true">>}
            ,{<<"Inherit-Codec">>, <<"false">>}
            ,{<<"Authorizing-Type">>, whapps_call:authorizing_type(Call)}
            ,{<<"Authorizing-ID">>, whapps_call:authorizing_id(Call)}
            ,{<<"OutBound-ID">>, OutboundId}
           ],

    Number = whapps_call:request_user(Call),
    Endpoint = 
    case State#state.myendpoint of
        'undefined' -> wh_json:from_list([{<<"Invite-Format">>, <<"route">>}
                            ,{<<"Route">>,  <<"loopback/", Number/binary, "/context_2">>}
                            ,{<<"To-DID">>, Number}
                            ,{<<"To-Realm">>, whapps_call:request_realm(Call)}
                            ,{<<"Custom-Channel-Vars">>, wh_json:from_list(CCVs)}]);
        E -> E
    end,

    %FIXME: codec renegotiation issues.
    [RequestUser, _] = binary:split(whapps_call:request(Call), <<"@">>),
    Request = props:filter_undefined(
                 [{<<"Application-Name">>, <<"park">>}
                 ,{<<"Originate-Immediate">>, 'true'}
                 ,{<<"Msg-ID">>, OutboundId}         
                 ,{<<"Endpoints">>, [Endpoint]}
                 ,{<<"Outbound-Caller-ID-Name">>, <<"Outbound Call">>}
                 ,{<<"Outbound-Caller-ID-Number">>, RequestUser}
                 ,{<<"Outbound-Callee-ID-Name">>, 'undefined'}
                 ,{<<"Outbound-Callee-ID-Number">>, 'undefined'}
                 ,{<<"Request">>, whapps_call:request(Call)}
                 ,{<<"From">>, whapps_call:from(Call)}
                 ,{<<"Dial-Endpoint-Method">>, <<"single">>}
                 ,{<<"Continue-On-Fail">>, 'false'}
                 ,{<<"Server-ID">>, Q}
                 ,{<<"Custom-Channel-Vars">>, wh_json:from_list(CCVs)}
                 ,{<<"Export-Custom-Channel-Vars">>, [<<"Account-ID">>, <<"Retain-CID">>
                                                     ,<<"Authorizing-ID">>, <<"Authorizing-Type">>
                                                     ,<<"OutBound-ID">>]}                                         
                 | wh_api:default_headers(<<"resource">>, <<"originate_req">>, ?APP_NAME, ?APP_VERSION)                                                                          
                ]),

    wapi_resource:publish_originate_req(Request),
    {'noreply', State};

handle_cast({'update_callid', CallId}, State) ->
    CtrlQ = channel_control_queue(CallId),
    lager:debug("jerry -- new callid ~p, new ctrl queue ~p", [CallId, CtrlQ]),
    Call = whapps_call:exec([
                        fun(C) -> whapps_call:set_call_id(CallId, C) end
                        ,fun(C) -> whapps_call:set_control_queue(CtrlQ, C) end]
                        ,State#state.mycall),
    case channel_answered(CallId) of 
        {'ok', 'true'} -> 
            %originate succeed and channel has answered.
            State#state.callerpid ! {'outbound_call_originated', Call},
            State#state.callerpid ! {'outbound_call_answered', Call};
        {'ok', 'false'} -> 
            %originate succeed and channel has not answered.
            Props = [{'callid', CallId},{'restrict_to', [<<"CHANNEL_ANSWER">>, <<"CHANNEL_DESTROY">>]}], 
            gen_listener:add_binding(self(), 'call', Props),
            State#state.callerpid ! {'outbound_call_originated', Call};
        'error' ->
            State#state.callerpid ! {'outbound_call_originate_failed', 'channel_not_exist'}
    end,
    {'noreply', State#state{mycall=Call}};


handle_cast({'originate_success', JObj}, State=#state{myendpoint=Endpoint}) when Endpoint =/= 'undefined' ->
    CallId = wh_json:get_value(<<"Call-ID">>, JObj),
    gen_listener:cast(self(), {'update_callid', CallId}),
    {'noreply', State};
    
%originate command failed
handle_cast({'originate_fail', _JObj}, State) ->
    State#state.callerpid ! {'outbound_call_originate_failed', 'originate_fail'},
    {'stop', {'shutdown', 'successful'}, State};

handle_cast({'channel_bridged', JObj}, State) ->
    OtherLegCallId = wh_json:get_binary_value(<<"Other-Leg-Call-ID">>, JObj),
    gen_listener:cast(self(), {'update_callid', OtherLegCallId}),
    {'noreply', State};

handle_cast({'channel_answered', _JObj}, State) ->
    State#state.callerpid ! {'outbound_call_answered', State#state.mycall},
    {'stop', {'shutdown', 'successful'}, State};

%callid has updated, but channel is destroyed after.
handle_cast({'channel_destroy', _JObj}, State) ->
    State#state.callerpid ! {'outbound_call_rejected', 'channel_destroyed'},
    {'stop', {'shutdown', 'successful'}, State};

handle_cast({'gen_listener',{'is_consuming',_IsConsuming}}, State) ->
    {'noreply', State};

handle_cast({'gen_listener',{'created_queue',_QueueName}}, State) ->
    gen_listener:cast(self(), 'originate_outbound_call'),
    {'noreply', State#state{myq=_QueueName}};

handle_cast(_Cast, State) ->
    lager:debug("unhandled cast: ~p", [_Cast]),
    {'noreply', State}.

handle_call('set_caller', {Pid, _}, State) ->
    {'reply', 'ok', State#state{callerpid=Pid}};
handle_call(_Request, _, P) ->
    {'reply', {'error', 'unimplemented'}, P}.

handle_event(JObj, State=#state{myendpoint=Endpoint}) when Endpoint =/= 'undefined' ->
    case whapps_util:get_event_type(JObj) of
        {<<"resource">>, <<"originate_resp">>} ->
            lager:debug("jerry -- got orignate response"),
            gen_listener:cast(State#state.server, {'originate_success', JObj});
        {<<"error">>, _} ->
            lager:debug("jerry -- received error response"),
            case wh_json:get_value(<<"Msg-ID">>, JObj) =:= State#state.outboundid of
                'true' -> gen_listener:cast(State#state.server, {'originate_fail', JObj});
                _R -> 'ok'
            end;
        {<<"call_event">>, <<"CHANNEL_ANSWER">>} ->
            lager:debug("jerry -- channel answered"),
            gen_listener:cast(State#state.server, {'channel_answered', JObj});
        {<<"call_event">>, <<"CHANNEL_DESTROY">>} ->
            lager:debug("jerry -- channel destroyed"),
            gen_listener:cast(State#state.server, {'channel_destroy', JObj});
        _R ->
            lager:debug("jerry -- received unexpected event ~p", [JObj])
    end,
    {'reply', []}.

terminate(_Reason, _ObConf) ->
    lager:debug("outbound_call execution has been stopped: ~p", [_Reason]).

code_change(_OldVsn, ObConf, _Extra) ->
    {'ok', ObConf}.

init([Endpoint, Call, CallerPid]) ->
    process_flag('trap_exit', 'true'),
    OutboundId = wh_util:rand_hex_binary(16),
    Server = outbound_call_manager:pid(),
    gen_listener:cast(Server, {'outbound_call_started', OutboundId, Call}),
    {'ok', #state{outboundid=OutboundId, mycall=Call, myendpoint=Endpoint, callerpid=CallerPid, server=self()}}.
