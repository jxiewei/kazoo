-module(broadcast_participant).

-behaviour(gen_listener).

-include_lib("whistle/include/wh_databases.hrl").
-include("broadcast.hrl").

%%API
-export([start/3
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

-record(state, {call :: whapps_call:call()
               ,type :: ne_binary()
               ,iteration :: pos_integer()
               ,status
               ,self :: pid()
               ,myq
               ,server :: pid()
               ,start_tstamp
               ,answer_tstamp
               ,hangup_tstamp
               ,hangupcause
               }).


start(Call, Type, Iteration) ->
    Bindings = [{'self', []}],
    gen_listener:start_link(?MODULE, [{'responders', ?RESPONDERS}
                                      ,{'bindings', Bindings} ,{'queue_name', ?QUEUE_NAME}
                                      ,{'queue_options', ?QUEUE_OPTIONS}
                                      ,{'consume_options', ?CONSUME_OPTIONS}
                                     ], [self(), Call, Type, Iteration]).

stop(Pid) ->
    gen_listener:cast(Pid, 'stop').

status(Pid) ->
    gen_listener:call(Pid, 'status').

join_conference(Call, ConferenceId, Moderator) ->
    case Moderator of
        'true' -> 
            Mute = 'false',
            EndConf = 'true';
        _ -> 
            Mute = 'true',
            EndConf = 'false'
    end,
    Command = [{<<"Application-Name">>, <<"conference">>}
            ,{<<"Conference-ID">>, ConferenceId}
            ,{<<"Mute">>, Mute}
            ,{<<"Deaf">>, 'false'}
            ,{<<"Moderator">>, Moderator}
            ,{<<"EndConf">>, EndConf}
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
    #state{call=Call} = State,
    gen_listener:cast(self(), 'init'),
    {'noreply', State#state{call=whapps_call:kvs_store('consumer_pid', self(), Call)
                           ,myq=_QueueName}};

handle_cast('answered', State) ->
    #state{call=Call, type=Type, iteration=Iteration} = State,
    lager:debug("Broadcast participant answered"),
    case Type of 
        {'file', _Moderator, MediaId} ->
            whapps_call_command:play(<<$/, (whapps_call:account_db(Call))/binary, $/, MediaId/binary>>, Call);
        {'recording', _Moderator, MediaId} ->
            whapps_call_command:play(<<$/, (whapps_call:account_db(Call))/binary, $/, MediaId/binary>>, Call);
        {'conference', Moderator, ConferenceId} ->
            join_conference(Call, ConferenceId, Moderator)
    end,
    {'noreply', State#state{status='online'
                           ,iteration=Iteration-1
                           ,answer_tstamp=wh_util:current_tstamp()}};

handle_cast({'originate_ready', JObj}, State) ->
    #state{call=Call, myq=Q} = State,
    CtrlQ = wh_json:get_value(<<"Control-Queue">>, JObj),
    Props = [{'callid', whapps_call:call_id(Call)}
                ,{'restrict_to'
                ,[<<"CHANNEL_EXECUTE_COMPLETE">>
                ,<<"CHANNEL_DESTROY">>
                ,<<"CHANNEL_ANSWER">>]
                }],
    gen_listener:add_binding(self(), 'call', Props),
    send_originate_execute(JObj, Q),

    {'noreply', State#state{call=whapps_call:set_control_queue(CtrlQ, Call)
                           ,status='proceeding'}};

handle_cast('originate_success', State) ->
    {'noreply', State#state{status='proceeding'}};


handle_cast('originate_failed', State) ->
    {'stop', 'normal', State#state{status='failed'
                                  ,hangupcause='originate_failed'
                                  ,hangup_tstamp=wh_util:current_tstamp()}};


%% other end hangup
handle_cast({'hangup', HangupCause}, State) ->
    lager:debug("Broadcast participant call hanged up"),
    Status = 
    case State#state.status of
        'online' -> 'offline';
        'succeeded' -> 'succeeded';
        'offline' -> 'offline';
        'interrupted' -> 'interrupted';
        _ -> 'failed'
    end,
    {'stop', 'normal', State#state{status=Status
                                  ,hangupcause=HangupCause
                                  ,hangup_tstamp=wh_util:current_tstamp()}};

%% All iteration of play succeeded, hangup.
handle_cast({'play_completed', <<"FILE PLAYED">>}, State=#state{iteration=Iter}) when Iter == 0 ->
    lager:debug("play complete, finished all iteration"),
    #state{call=Call} = State,
    whapps_call_command:hangup(Call),
    {'stop', 'normal', State#state{status='succeeded'}};

%% One iteration of play succeed, continue.
handle_cast({'play_completed', <<"FILE PLAYED">>}, State=#state{iteration=Iter}) when Iter > 0 ->
    lager:debug("play complete, ~p iteration remained", [Iter]),
    #state{type=Type, call=Call} = State,
    case Type of 
        {'file', _Moderator, MediaId} ->
            whapps_call_command:play(<<$/, (whapps_call:account_db(Call))/binary, $/, MediaId/binary>>, Call);
        {'recording', _Moderator, MediaId} ->
            whapps_call_command:play(<<$/, (whapps_call:account_db(Call))/binary, $/, MediaId/binary>>, Call);
        _ -> 'ok'
    end,
    {'noreply', State#state{iteration=Iter-1}};

%% Interrupted by peer
handle_cast({'play_completed', Result}, State) ->
    #state{call=Call} = State,
    lager:info("Broadcast playback may be interrupted by peer, result ~p", [Result]),
    whapps_call_command:hangup(Call),
    {'stop', 'normal', State#state{status='interrupted'}};

handle_cast('init', State) ->
    #state{call=Call, myq=Q} = State,
    MsgId = wh_util:rand_hex_binary(16),
    lager:debug("Initializing broadcast participant ~p, msgid ~p", [whapps_call:to_user(Call), MsgId]),

    AccountId = whapps_call:account_id(Call),
    [Number, _] = binary:split(whapps_call:to(Call), <<"@">>),

    case cf_util:lookup_callflow(Number, AccountId) of
        {'ok', Flow, _NoMatch} ->
            Request = broadcast_util:build_offnet_request(wh_json:get_value([<<"flow">>, <<"data">>], Flow), Call, Q),
            wapi_offnet_resource:publish_req(Request);
        {'error', Reason} ->
            lager:info("Lookup callflow for ~s in account ~s failed: ~p", [Number, AccountId, Reason]),
            gen_listener:cast(self(), 'originate_failed')
    end,
    {'noreply', State};

%% Our end stop brutally
handle_cast('stop', State) ->
    lager:debug("Stopping broadcast participant"),
    #state{call=Call} = State,
    whapps_call_command:hangup(Call),
    {'stop', {'shutdown', 'stopped'}, State#state{status='interrupted'}};

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

-spec send_originate_execute(wh_json:object(), ne_binary()) -> 'ok'.
send_originate_execute(JObj, Q) ->
    CallId = wh_json:get_value([<<"Resource-Response">>, <<"Call-ID">>], JObj),
    MsgId = wh_json:get_value([<<"Resource-Response">>, <<"Msg-ID">>], JObj),
    ServerId = wh_json:get_value([<<"Resource-Response">>, <<"Server-ID">>], JObj),

    Prop = [{<<"Call-ID">>, CallId}
            ,{<<"Msg-ID">>, MsgId}
            | wh_api:default_headers(Q, ?APP_NAME, ?APP_VERSION)
           ],
    wapi_dialplan:publish_originate_execute(ServerId, Prop).

handle_event(JObj, State) ->
    #state{self=Pid} = State,
    lager:debug("received call event, ~p", [JObj]),
    case whapps_util:get_event_type(JObj) of
        {<<"resource">>, <<"offnet_resp">>} ->
            case wh_json:get_value(<<"Response-Message">>, JObj) of
                <<"READY">> ->
                    gen_listener:cast(Pid, {'originate_ready', JObj});
                _ ->
                    lager:info("Offnet request failed: ~p", [JObj]),
                    gen_listener:cast(Pid, 'originate_failed')
            end;
        {<<"resource">>, <<"originate_resp">>} ->
            case wh_json:get_value(<<"Application-Response">>, JObj) =:= <<"SUCCESS">> of
                'true' -> gen_listener:cast(Pid, 'originate_success');
                'false' -> gen_listener:cast(Pid, 'originate_failed')
            end;
        {<<"error">>, <<"originate_resp">>} ->
            lager:debug("channel execution error while waiting for originate: ~s"
                        ,[wh_util:to_binary(wh_json:encode(JObj))]),
            gen_listener:cast(Pid, 'originate_failed');
        {<<"call_event">>, <<"CHANNEL_EXECUTE_COMPLETE">>} ->
            lager:debug("received CHANNEL_EXECUTE_COMPLETE event, app is ~p", [get_app(JObj)]),
            case get_app(JObj) of
                <<"play">> -> gen_listener:cast(Pid, {'play_completed', get_app_response(JObj)});
                _ -> 'ok'
            end;
        {<<"call_event">>, <<"CHANNEL_DESTROY">>} ->
            HangupCause = wh_json:get_value(<<"Hangup-Cause">>, JObj, <<"unknown">>),
            gen_listener:cast(Pid, {'hangup', HangupCause});
        {<<"call_event">>, <<"CHANNEL_ANSWER">>} ->
            gen_listener:cast(Pid, 'answered');
        _Else ->
            lager:debug("unhandled event ~p", [JObj])
    end,
    {'reply', []}.

is_final_state('initial') -> 'false';
is_final_state('proceeding') -> 'false';
is_final_state('online') -> 'false';
is_final_state(_) -> 'true'.

terminate(Reason, State) ->
    #state{call=Call, status=Status} = State, 

    %%If call already terminated, honor it's state, otherwise use terminate reason.
    FinalState = case is_final_state(Status) of
        'true' -> Status;
        'false' -> 'interrupted'
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

init([Server, Call, Type, Iteration]) ->
    process_flag('trap_exit', 'true'),
    CallId = wh_util:rand_hex_binary(8),
    put('callid', CallId),
    {'ok', #state{call=whapps_call:set_call_id(CallId, Call)
                 ,type=Type
                 ,iteration=Iteration
                 ,self=self()
                 ,server=Server
                 ,status='initial'
                 ,start_tstamp=wh_util:current_tstamp()}
    }.


