-module(broadcast_participant).

-behaviour(gen_listener).

-include_lib("whistle/include/wh_databases.hrl").
-include("broadcast.hrl").

%%API
-export([start/2
        ,stop/1
        ,status/1]).

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
-define(SUCCESSFUL_HANGUP_CAUSES, [<<"NORMAL_CLEARING">>, <<"ORIGINATOR_CANCEL">>, <<"SUCCESS">>]).

-record(state, {call :: whapps_call:call()
               ,type :: ne_binary()
               ,status
               ,self :: pid()
               ,myq
               ,server :: pid()
               ,start_tstamp
               ,answer_tstamp
               ,hangup_tstamp
               ,hangupcause
               }).


start(Call, Type) ->
    Bindings = [{'self', []}],
    gen_listener:start_link(?MODULE, [{'responders', ?RESPONDERS}
                                      ,{'bindings', Bindings} ,{'queue_name', ?QUEUE_NAME}
                                      ,{'queue_options', ?QUEUE_OPTIONS}
                                      ,{'consume_options', ?CONSUME_OPTIONS}
                                     ], [self(), Call, Type]).

stop(Pid) ->
    gen_listener:cast(Pid, 'stop').

status(Pid) ->
    gen_listener:call(Pid, 'status').

join_conference(Call, ConferenceId, Moderator) ->
    case Moderator of
        'true' -> Mute = 'false';
        _ -> Mute = 'true'
    end,
    Command = [{<<"Application-Name">>, <<"conference">>}
            ,{<<"Conference-ID">>, ConferenceId}
            ,{<<"Mute">>, Mute}
            ,{<<"Deaf">>, 'false'}
            ,{<<"Moderator">>, Moderator}
            ,{<<"Profile">>, <<"default">>}
            ],
    whapps_call_command:send_command(Command, Call). 


handle_call('status', _From, #state{status=Status}=State) ->
    {'reply', {'ok', Status}, State};

handle_call(_Request, _From, State) ->
    {'reply', {'error', 'unimplemented'}, State}.

handle_info(_Msg, State) ->
    lager:debug("unhandled message: ~p", [_Msg]),
    {'noreply', State}.

handle_cast({'gen_listener',{'is_consuming',_IsConsuming}}, State) ->
    {'noreply', State};

handle_cast({'gen_listener',{'created_queue',_QueueName}}, State) ->
    gen_listener:cast(self(), 'init'),
    {'noreply', State#state{myq=_QueueName}};

handle_cast('channel_answered', State) ->
    #state{call=Call, type=Type} = State,
    lager:debug("Broadcast participant answered"),
    case Type of 
        {'file', _Moderator, MediaId} ->
            whapps_call_command:play(<<$/, (whapps_call:account_db(Call))/binary, $/, MediaId/binary>>, Call);
        {'conference', Moderator, ConferenceId} ->
            join_conference(Call, ConferenceId, Moderator)
    end,
    {'noreply', State#state{status='online'
                           ,answer_tstamp=wh_util:current_tstamp()}};

handle_cast({'originate_uuid', CallId, CtrlQ}, State) ->
    #state{call=Call} = State,
    NewCall = whapps_call:exec([fun(C) -> whapps_call:set_call_id(CallId, C) end,
                    fun(C) -> whapps_call:set_control_queue(CtrlQ, C) end], Call),
    {'noreply', State#state{call=NewCall}};

handle_cast({'outbound_call_originated', NewCallId}, State) ->
    case NewCallId of
        'undefined' -> 
            {'noreply', State#state{status='failed'}};
        _ ->
            lager:debug("Participant outbound call originated"),
            #state{call=Call} = State,
            Props = [{'callid', NewCallId}
                ,{'restrict_to',
                [<<"CHANNEL_EXECUTE_COMPLETE">>
                ,<<"CHANNEL_DESTROY">>
                ,<<"CHANNEL_ANSWER">>]
                }],
            gen_listener:add_binding(self(), 'call', Props),
            {'noreply', State#state{status='proceeding', call=whapps_call:set_call_id(NewCallId, Call)}}
    end;

handle_cast({'outbound_call_hangup', HangupCause}, State) ->
    lager:debug("Broadcast participant call hanged up"),
    Status = 
    case State#state.status of
        'online' -> 'offline';
        'succeeded' -> 'succeeded';
        'offline' -> 'offline';
        _ -> 'failed'
    end,
    {'stop', 'normal', State#state{status=Status
                                  ,hangupcause=HangupCause
                                  ,hangup_tstamp=wh_util:current_tstamp()}};

handle_cast({'play_completed', Result}, State) ->
    lager:debug("Finished playing to broadcast participant, result is ~p", [Result]),
    #state{call=Call} = State,
    whapps_call_command:hangup(Call),
    case Result of
        <<"FILE PLAYED">> -> 
            {'noreply', State#state{status='succeeded'}};
        _ -> 
            lager:info("Broadcast playback may be interrupted by peer, result ~p", [Result]),
            {'noreply', State#state{status='failed'}} 
    end;

handle_cast('init', State) ->
    #state{call=Call, myq=Q} = State,
    lager:debug("Initializing broadcast participant ~p", [whapps_call:to_user(Call)]),

    AccountId = whapps_call:account_id(Call),
    CCVs = [{<<"Account-ID">>, AccountId}
            ,{<<"Retain-CID">>, <<"true">>}
            ,{<<"Inherit-Codec">>, <<"false">>}
            ,{<<"Authorizing-Type">>, whapps_call:authorizing_type(Call)}
            ,{<<"Authorizing-ID">>, whapps_call:authorizing_id(Call)}
           ],

    [Number, _] = binary:split(whapps_call:to(Call), <<"@">>),
    Endpoint = wh_json:from_list([{<<"Invite-Format">>, <<"route">>}
                            ,{<<"Route">>,  <<Number/binary, "@211.154.153.118">>}
                            ,{<<"To-DID">>, Number}
                            ,{<<"To-Realm">>, whapps_call:request_realm(Call)}
                            ,{<<"Custom-Channel-Vars">>, wh_json:from_list(CCVs)}]),

    MsgId = wh_util:rand_hex_binary(16),
    %FIXME: codec renegotiation issues.
    [RequestUser, _] = binary:split(whapps_call:request(Call), <<"@">>),
    Request = props:filter_undefined(
                 [{<<"Application-Name">>, <<"park">>}
                 ,{<<"Originate-Immediate">>, 'true'}
                 ,{<<"Msg-ID">>, MsgId}         
                 ,{<<"Endpoints">>, [Endpoint]}
                 ,{<<"Outbound-Caller-ID-Name">>, <<"Broadcast Call">>}
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
                                                     ,<<"Authorizing-ID">>, <<"Authorizing-Type">>]}                                         
                 | wh_api:default_headers(<<"resource">>, <<"originate_req">>, ?APP_NAME, ?APP_VERSION)                                                                          
                ]),
    wapi_resource:publish_originate_req(Request),
    {'noreply', State};

handle_cast('stop', State) ->
    lager:debug("Stopping broadcast participant"),
    #state{call=Call} = State,
    whapps_call_command:hangup(Call),
    {'stop', {'shutdown', 'stopped'}, State};

handle_cast(_Cast, State) ->
    lager:debug("unhandled cast: ~p", [_Cast]),
    {'noreply', State}.

-spec get_app(wh_json:object()) -> api_binary().
get_app(JObj) ->
    wh_json:get_first_defined([<<"Application-Name">>
                            ,[<<"Request">>, <<"Application-Name">>]
                            ], JObj).
get_app_response(JObj) ->
    wh_json:get_value(<<"Application-Response">>, JObj).

handle_event(JObj, State) ->
    #state{self=Pid} = State,
    lager:debug("received call event, ~p", [JObj]),
    case whapps_util:get_event_type(JObj) of
        {<<"resource">>, <<"originate_uuid">>} ->
            gen_listener:cast(Pid, {'originate_uuid'
                                    ,wh_json:get_value(<<"Outbound-Call-ID">>, JObj)
                                    ,wh_json:get_value(<<"Outbound-Call-Control-Queue">>, JObj)
                              });
        {<<"resource">>, <<"originate_resp">>} ->
            AppResponse = wh_json:get_first_defined([<<"Application-Response">> ,<<"Hangup-Cause">> ,<<"Error-Message">>], JObj),
            NewCallId = 
            case lists:member(AppResponse, ?SUCCESSFUL_HANGUP_CAUSES) of
                'true' -> wh_json:get_value(<<"Call-ID">>, JObj);
                'false' when AppResponse =:= 'undefined' -> wh_json:get_value(<<"Call-ID">>, JObj);
                'false' -> 
                    lager:debug("app response ~s not successful: ~p", [AppResponse, JObj]),
                    'undefined'
            end,
            gen_listener:cast(Pid, {'outbound_call_originated', NewCallId});
        {<<"call_event">>, <<"CHANNEL_EXECUTE_COMPLETE">>} ->
            lager:debug("received CHANNEL_EXECUTE_COMPLETE event, app is ~p", [get_app(JObj)]),
            case get_app(JObj) of
                <<"play">> -> gen_listener:cast(Pid, {'play_completed', get_app_response(JObj)});
                _ -> 'ok'
            end;
        {<<"call_event">>, <<"CHANNEL_DESTROY">>} ->
            HangupCause = wh_json:get_value(<<"Hangup-Cause">>, JObj, <<"unknown">>),
            gen_listener:cast(Pid, {'outbound_call_hangup', HangupCause});
        {<<"call_event">>, <<"CHANNEL_ANSWER">>} ->
            gen_listener:cast(Pid, 'channel_answered');
        _Else ->
            lager:debug("jerry -- unhandled event ~p", [JObj])
    end,
    {'reply', []}.

is_final_state('initial') -> 'false';
is_final_state('proceeding') -> 'false';
is_final_state('online') -> 'false';
is_final_state(_) -> 'true'.

reason_to_final_state('normal') -> 'interrupted';
reason_to_final_state('shutdown') -> 'interrupted';
reason_to_final_state({'shutdown', _}) -> 'interrupted';
reason_to_final_state(_) -> 'exception'.

terminate(Reason, State) ->
    #state{call=Call, status=Status} = State, 
    FinalState = case is_final_state(Status) of
        'true' -> Status;
        'false' -> reason_to_final_state(Reason)
    end,
    PartyLog = #partylog{
        tasklogid='undefined'
        ,call_id=whapps_call:call_id(Call)
        ,caller_id_number=whapps_call:caller_id_number(Call)
        ,callee_id_number=whapps_call:callee_id_number(Call)
        ,start_tstamp=State#state.start_tstamp
        ,end_tstamp=wh_util:current_tstamp()
        ,answer_tstamp=State#state.answer_tstamp
        ,hangup_tstamp=State#state.hangup_tstamp
        ,final_state=FinalState
        ,hangup_cause=State#state.hangupcause
        ,owner_id='undefined'
    },
    gen_listener:cast(State#state.server, {'participant_exited', PartyLog}),
    lager:info("broadcast_participant execution has been stopped: ~p", [Reason]).

code_change(_OldVsn, State, _Extra) ->
    {'ok', State}.

init([Server, Call, Type]) ->
    process_flag('trap_exit', 'true'),
    {'ok', #state{call=Call
                 ,type=Type
                 ,self=self()
                 ,server=Server
                 ,status='initial'
                 ,start_tstamp=wh_util:current_tstamp()}
    }.
