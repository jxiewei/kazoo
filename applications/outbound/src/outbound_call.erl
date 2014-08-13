-module(outbound_call).

-behaviour(gen_listener).

-include_lib("whistle/include/wh_databases.hrl").
-include("outbound.hrl").

%%API
-export([start_link/4
        ,start/1, start/2
        ,stop/1, status/1
        ,test/3
        ,wait_answer/1, wait_answer/2
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
-define(DEFAULT_ORIGINATE_TIMEOUT, 30000).
-define(DEFAULT_ANSWER_TIMEOUT, 30000).

-define(RESPONDERS, []).
-define(QUEUE_NAME, <<>>).
-define(QUEUE_OPTIONS, []).
-define(CONSUME_OPTIONS, []).

-record(state, {outboundid :: ne_binary()
               ,mycall :: whapps_call:call()
               ,myendpoint
               ,from
               ,myq
               ,exiting
               ,status :: atom()
               ,server}).

%% API

start_link(Id, Endpoint, Call, From) ->
    Bindings = [{'self', []}],
    gen_listener:start_link(?MODULE, [{'responders', ?RESPONDERS}
                                      ,{'bindings', Bindings}
                                      ,{'queue_name', ?QUEUE_NAME}
                                      ,{'queue_options', ?QUEUE_OPTIONS}
                                      ,{'consume_options', ?CONSUME_OPTIONS}
                                     ], [Id, Endpoint, Call, From]).

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
wait_answer(Pid) ->
    wait_answer(Pid, ?DEFAULT_ANSWER_TIMEOUT).
wait_answer(Pid, After) ->
    Start = erlang:now(),
    case (catch status(Pid)) of
        'answered' -> 'ok';
        {'EXIT', _} -> {'error', 'stopped'};
        _ ->
            timer:sleep(1000),
            wait_answer(Pid, whapps_util:decr_timeout(After, Start))
    end.

test(AccountId, UserId, Number) ->
    AccountDb = wh_util:format_account_id(AccountId, 'encoded'),
    {'ok', Account} = couch_mgr:open_cache_doc(?WH_ACCOUNTS_DB, AccountId),
    {'ok', User} = couch_mgr:open_cache_doc(AccountDb, UserId),
    CallerId = wh_json:get_value([<<"caller_id">>, <<"external">>], User),
    FromUser = wh_json:get_value(<<"number">>, CallerId),
    Realm = wh_json:get_ne_value(<<"realm">>, Account),

    Call = whapps_call:exec([
               fun(C) -> whapps_call:set_authorizing_type(<<"user">>, C) end
               ,fun(C) -> whapps_call:set_authorizing_id(UserId, C) end
               ,fun(C) -> whapps_call:set_request(<<FromUser/binary, <<"@">>/binary, Realm/binary>>, C) end
               ,fun(C) -> whapps_call:set_to(<<Number/binary, <<"@">>/binary, Realm/binary>>, C) end
               ,fun(C) -> whapps_call:set_account_db(AccountDb, C) end
               ,fun(C) -> whapps_call:set_account_id(AccountId, C) end
               ,fun(C) -> whapps_call:set_caller_id_name(wh_json:get_value(<<"name">>, CallerId), C) end
               ,fun(C) -> whapps_call:set_caller_id_number(wh_json:get_value(<<"number">>, CallerId), C) end
               ,fun(C) -> whapps_call:set_callee_id_name(Number, C) end
               ,fun(C) -> whapps_call:set_callee_id_number(Number, C) end
               ,fun(C) -> whapps_call:set_owner_id(UserId, C) end]
               ,whapps_call:new()),
    start(Call).
            
start(Call) ->
    {'ok', Pid} = outbound_call_manager:start('undefined', Call),
    case wait_originate(?DEFAULT_ORIGINATE_TIMEOUT) of
        {'ok', Ret} -> 
            {'ok', Pid, Ret};
        _Return ->
            lager:debug("outbound originate timeout in ~p seconds", [?DEFAULT_ORIGINATE_TIMEOUT/1000]),
            stop(Pid),
            _Return
    end.

start(Endpoint, Call) ->
    {'ok', Pid} = outbound_call_manager:start(Endpoint, Call),
    case wait_originate(?DEFAULT_ORIGINATE_TIMEOUT) of
        {'ok', ObCall} -> 
            {'ok', Pid, ObCall};
        _Return -> 
            lager:debug("outbound originate timeout in ~p seconds", [?DEFAULT_ORIGINATE_TIMEOUT/1000]),
            stop(Pid),
            _Return
    end.

stop(Pid) when is_pid(Pid) ->
    gen_listener:cast(Pid, 'stop').

status(Pid) when is_pid(Pid) ->
    gen_listener:call(Pid, 'status').

%% Callbacks
handle_info(_Msg, State) ->
    lager:info("unhandled message: ~p", [_Msg]),
    {'noreply', State}.

handle_cast('originate_outbound_call', State) ->
    #state{outboundid=OutboundId, mycall=Call, myq=Q} = State,
    put('callid', OutboundId),
    lager:debug("Originating outbound call"),
    AccountId = whapps_call:account_id(Call),

    CCVs = [{<<"Account-ID">>, AccountId}
            ,{<<"Retain-CID">>, <<"true">>}
            ,{<<"Inherit-Codec">>, <<"false">>}
            ,{<<"Authorizing-Type">>, whapps_call:authorizing_type(Call)}
            ,{<<"Authorizing-ID">>, whapps_call:authorizing_id(Call)}
            ,{<<"OutBound-ID">>, OutboundId}
           ],

    [Number, _] = binary:split(whapps_call:to(Call), <<"@">>),
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
    {'noreply', State#state{status='initial'}};

handle_cast({'update_callid', CallId}, State) ->
    #state{mycall=MyCall} = State,
    case whapps_call_command:b_channel_status(CallId) of
        {'ok', JObj} -> 
            lager:debug("Got channel status response ~p", [JObj]),
            CtrlQ = wh_json:get_value(<<"Control-Queue">>, JObj),
            Answered = wh_json:get_value(<<"Answered">>, JObj),
            lager:debug("New callid ~p, ctrl queue ~p, answered ~p", [CallId, CtrlQ, Answered]),
            Call = whapps_call:exec([
                        fun(C) -> whapps_call:set_call_id(CallId, C) end
                        ,fun(C) -> whapps_call:set_control_queue(CtrlQ, C) end]
                        ,MyCall),
            Props = [{'callid', CallId},{'restrict_to', [<<"CHANNEL_DESTROY">>]}], 
            gen_listener:add_binding(self(), 'call', Props),
            case Answered of 
                'true' ->
                    %originate succeed and channel has answered.
                    State#state.from ! {'outbound_call_originated', Call},
                    {'noreply', State#state{mycall=Call, status='answered'}};
                _ -> 
                    %originate succeed and channel has not answered.
                    Props1 = [{'callid', CallId},{'restrict_to', [<<"CHANNEL_ANSWER">>]}], 
                    gen_listener:add_binding(self(), 'call', Props1),
                    State#state.from ! {'outbound_call_originated', Call},
                    {'noreply', State#state{mycall=Call, status='proceeding'}}
            end;
        {'error', Reason} ->
            lager:info("Failed to get channel status of ~p, reason is ~p", [CallId, Reason]),
            gen_listener:cast(self(), 'stop'),
            {'noreply', State} 
    end;

handle_cast({'originate_success', _JObj}, State) ->
    %CallId = wh_json:get_value(<<"Call-ID">>, JObj),
    %gen_listener:cast(self(), {'update_callid', CallId}),
    {'noreply', State};
    
%originate command failed
handle_cast({'originate_fail', _JObj}, State) ->
    lager:debug("outbound call originate failed"),
    State#state.from ! {'outbound_call_originate_failed', 'originate_fail'},
    gen_listener:cast(self(), 'stop'),
    {'noreply', State};

handle_cast({'channel_bridged', JObj}, State) ->
    OtherLegCallId = wh_json:get_binary_value(<<"Other-Leg-Call-ID">>, JObj),
    lager:debug("outbound call bridged to ~p", [OtherLegCallId]),
    gen_listener:cast(self(), {'update_callid', OtherLegCallId}),
    {'noreply', State};

handle_cast({'channel_answered', _JObj}, State) ->
    lager:debug("outbound call answered"),
    {'noreply', State#state{status='answered'}};

%callid has updated, but channel is destroyed after.
handle_cast({'channel_destroy', _JObj}, State) ->
    lager:debug("outbound call destroyed"),
    gen_listener:cast(self(), 'stop'),
    {'noreply', State};

handle_cast({'gen_listener',{'is_consuming',_IsConsuming}}, State) ->
    {'noreply', State};

handle_cast({'gen_listener',{'created_queue',_QueueName}}, State) ->
    gen_listener:cast(self(), 'originate_outbound_call'),
    {'noreply', State#state{myq=_QueueName}};


%% TODO: Do not exit immediately to hangup calls ringed already but not answered yet.
%% to avoid ghost call. Issue here is for voip calls, we haven't got callid yet.
%% Voip calls CHANNEL_BRIDGE occurs only after callee answered.
handle_cast('stop', #state{mycall=Call, outboundid=ObId}=State) ->
    lager:debug("Trying to stop outbound call"),
    case whapps_call:control_queue(Call) of
        'undefined' -> 
            {'stop', {'shutdown', {ObId, 'stopped'}}, State};
        _ ->
            whapps_call_command:hangup(Call),
            {'stop', {'shutdown', {ObId, 'stopped'}}, State}
    end;

handle_cast(_Cast, State) ->
    lager:debug("unhandled cast: ~p", [_Cast]),
    {'noreply', State}.

handle_call('status', _From, State) ->
    #state{status=Status} = State,
    {'reply', {'ok', Status}, State};

handle_call(_Request, _, P) ->
    {'reply', {'error', 'unimplemented'}, P}.

handle_event(JObj, State) ->
    case whapps_util:get_event_type(JObj) of
        {<<"resource">>, <<"originate_resp">>} ->
            gen_listener:cast(State#state.server, {'originate_success', JObj});
        {<<"error">>, _} ->
            case wh_json:get_value(<<"Msg-ID">>, JObj) =:= State#state.outboundid of
                'true' -> gen_listener:cast(State#state.server, {'originate_fail', JObj});
                _R -> 'ok'
            end;
        {<<"call_event">>, <<"CHANNEL_ANSWER">>} ->
            gen_listener:cast(State#state.server, {'channel_answered', JObj});
        {<<"call_event">>, <<"CHANNEL_DESTROY">>} ->
            gen_listener:cast(State#state.server, {'channel_destroy', JObj});
        _R -> 'ok'
    end,
    {'reply', []}.

terminate(_Reason, _ObConf) ->
    lager:debug("outbound call terminated: ~p", [_Reason]).

code_change(_OldVsn, ObConf, _Extra) ->
    {'ok', ObConf}.

init([Id, Endpoint, Call, From]) ->
    process_flag('trap_exit', 'true'),
    N = wh_util:to_binary(node()),
    [_, Host] = binary:split(N, <<"@">>),
    FSNode = wh_util:to_atom(<<"freeswitch@", Host/binary>>, 'true'),
    C = whapps_call:exec([
            fun(C) -> whapps_call:set_switch_nodename(FSNode, C) end
            ,fun(C) -> whapps_call:set_switch_hostname(Host, C) end], Call),
    {'ok', #state{outboundid=Id
                 ,mycall=C
                 ,myendpoint=Endpoint
                 ,from=From
                 ,status='initial'
                 ,exiting='false'
                 ,server=self()}}.
