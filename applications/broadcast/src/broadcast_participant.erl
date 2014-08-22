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
    #state{call=Call} = State,
    gen_listener:cast(self(), 'init'),
    {'noreply', State#state{call=whapps_call:kvs_store('consumer_pid', self(), Call)
                           ,myq=_QueueName}};

handle_cast('answered', State) ->
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

handle_cast({'play_completed', Result}, State) ->
    lager:debug("Finished playing to broadcast participant, result is ~p", [Result]),
    #state{call=Call} = State,
    whapps_call_command:hangup(Call),
    case Result of
        %% normally completed
        <<"FILE PLAYED">> -> 
            {'stop', 'normal', State#state{status='succeeded'}};
        %% Interrupted by peer
        _ -> 
            lager:info("Broadcast playback may be interrupted by peer, result ~p", [Result]),
            {'stop', 'normal', State#state{status='interrupted'}} 
    end;


handle_cast('init', State) ->
    #state{call=Call, myq=Q} = State,
    MsgId = wh_util:rand_hex_binary(16),
    lager:debug("Initializing broadcast participant ~p, msgid ~p", [whapps_call:to_user(Call), MsgId]),

    AccountId = whapps_call:account_id(Call),
    [Number, _] = binary:split(whapps_call:to(Call), <<"@">>),

    case cf_util:lookup_callflow(Number, AccountId) of
        {'ok', Flow, _NoMatch} ->
            Request = build_offnet_request(wh_json:get_value([<<"flow">>, <<"data">>], Flow), Call, Q),
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

init([Server, Call, Type]) ->
    process_flag('trap_exit', 'true'),
    CallId = wh_util:rand_hex_binary(8),
    put('callid', CallId),
    {'ok', #state{call=whapps_call:set_call_id(CallId, Call)
                 ,type=Type
                 ,self=self()
                 ,server=Server
                 ,status='initial'
                 ,start_tstamp=wh_util:current_tstamp()}
    }.

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

