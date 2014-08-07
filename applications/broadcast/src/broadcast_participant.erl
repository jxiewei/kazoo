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

-record(state, {call :: whapps_call:call()
               ,obcall :: whapps_call:call()
               ,obid :: binary()
               ,media :: ne_binary()
               ,status
               ,self :: pid()
               ,server :: pid()
               ,start_tstamp
               ,answer_tstamp
               ,hangup_tstamp
               ,hangupcause
               }).


start(Call, Media) ->
    Bindings = [{'self', []}],
    gen_listener:start_link(?MODULE, [{'responders', ?RESPONDERS}
                                      ,{'bindings', Bindings} ,{'queue_name', ?QUEUE_NAME}
                                      ,{'queue_options', ?QUEUE_OPTIONS}
                                      ,{'consume_options', ?CONSUME_OPTIONS}
                                     ], [self(), Call, Media]).

stop(Pid) ->
    gen_listener:cast(Pid, 'stop').

status(Pid) ->
    gen_listener:call(Pid, 'status').

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
    {'noreply', State};

handle_cast('channel_answered', State) ->
    #state{obcall=ObCall, media=Media} = State,
    lager:debug("Broadcast participant answered"),
    whapps_call_command:play(<<$/, (whapps_call:account_db(ObCall))/binary, $/, Media/binary>>, ObCall),
    {'noreply', State#state{status='online'
                           ,answer_tstamp=wh_util:current_tstamp()}};

handle_cast('outbound_call_originated', State) ->
    lager:debug("Participant outbound call originated"),
    #state{obcall=ObCall, obid=ObId} = State,
    case outbound_call:status(ObId) of
        {'ok', 'answered'} ->
            gen_listener:cast(self(), 'channel_answered');
        _ -> 'ok'
    end,
    Props = [{'callid', whapps_call:call_id(ObCall)} 
            ,{'restrict_to',
              [<<"CHANNEL_EXECUTE_COMPLETE">>
              ,<<"CHANNEL_DESTROY">>
              ,<<"CHANNEL_ANSWER">>]
           }],
    gen_listener:add_binding(self(), 'call', Props),
    {'noreply', State};

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
    outbound_call:stop(State#state.obid),
    case Result of
        <<"FILE PLAYED">> -> 
            {'noreply', State#state{status='succeeded'}};
        _ -> 
            lager:info("Broadcast playback may be interrupted by peer, result ~p", [Result]),
            {'noreply', State#state{status='failed'}} 
    end;

handle_cast('init', State) ->
    #state{call=Call} = State,
    lager:debug("Initializing broadcast participant ~p", [whapps_call:to_user(Call)]),
    case outbound_call:start(Call) of
        {'ok', ObId, ObCall} ->
            put('callid', whapps_call:call_id(ObCall)),
            gen_listener:cast(self(), 'outbound_call_originated'),
            {'noreply', State#state{obcall=ObCall, obid=ObId, status='proceeding'}};
        {'error', _Reason} ->
            lager:error("Call broadcast participant failed"),
           {'noreply', State#state{status='failed'}};
        _Else ->
           {'noreply', State}
    end;

handle_cast('stop', State) ->
    lager:debug("Stopping broadcast participant"),
    outbound_call:stop(State#state.obid),
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
    #state{obcall=Call, status=Status} = State, 
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

init([Server, Call, Media]) ->
    process_flag('trap_exit', 'true'),
    {'ok', #state{call=Call
                 ,media=Media
                 ,self=self()
                 ,server=Server
                 ,status='initial'
                 ,start_tstamp=wh_util:current_tstamp()}
    }.
