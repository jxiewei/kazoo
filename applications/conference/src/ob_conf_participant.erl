%%NOTE: In this mod, we doesn't consume_all_events, to reduce amqp message load.
%%So whapps_call_command:b_* API can't be used here, they relys on various call events.
-module(ob_conf_participant).

-behaviour(gen_listener).

-include_lib("whistle/include/wh_databases.hrl").
-include("conference.hrl").

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

-record(state, {conference
                ,de
                ,call :: whapps_call:call()
                ,obcall :: whapps_call:call()
                ,obid
                ,status
                ,server :: pid()
                ,self :: pid()
                ,myq
                ,start_tstamp
                ,answer_tstamp
                ,hangup_tstamp
                ,hangupcause
               }).

start(Conference, Call) ->
    Bindings = [{'self', []}],    
    gen_listener:start_link(?MODULE, [{'responders', ?RESPONDERS}
                                      ,{'bindings', Bindings} ,{'queue_name', ?QUEUE_NAME}
                                      ,{'queue_options', ?QUEUE_OPTIONS}
                                      ,{'consume_options', ?CONSUME_OPTIONS}
                                     ], [self(), Conference, Call]).

stop(Pid) ->
    gen_listener:cast(Pid, 'stop').

status(Pid) ->
    gen_listener:call(Pid, 'status').

handle_call('status', _From, State) ->
    {'reply', {'ok', State#state.status}, State};

handle_call(_Request, _, P) ->
    {'reply', {'error', 'unimplemented'}, P}.

handle_info(_Msg, State) ->
    lager:info("Unhandled message: ~p", [_Msg]),
    {'noreply', State}.

handle_cast({'gen_listener',{'is_consuming',_IsConsuming}}, State) ->
    {'noreply', State};

handle_cast({'gen_listener',{'created_queue',_QueueName}}, State) ->
    lager:debug("created_queue ~p", [_QueueName]),
    DE = wh_json:from_list([{<<"Server-ID">>, _QueueName}
                           ,{<<"Conference-Doc">>, State#state.conference}]),
    gen_listener:cast(self(), 'init'),
    {'noreply', State#state{de=DE, myq=_QueueName}};

handle_cast('channel_answered', State) ->
    lager:debug("Channel answered"),
    #state{obcall=ObCall} = State,
    %whapps_call_command:prompt(<<"conf-welcome">>, ObCall),
    %{'ok', Srv} = conf_participant_sup:start_participant(ObCall),
    %conf_participant:set_discovery_event(State#state.de, Srv),
    Conference = conf_discovery_req:create_conference(State#state.conference, 
            whapps_call:to_user(ObCall)),
    %lager:debug("Searching for conference"),
    %conf_participant:consume_call_events(Srv),
    %conf_discovery_req:search_for_conference(Conference, ObCall, Srv),

    conf_participant:send_conference_command(Conference, ObCall),

    %%FIXME: store Call to calls
    {'noreply', State#state{status='online'
                            ,answer_tstamp=wh_util:current_tstamp()}};

handle_cast('outbound_call_originated', State) ->
    #state{obcall=ObCall, obid=ObId} = State,
    lager:info("Participant outbound call originated, obid is ~p", [ObId]),
    case outbound_call:status(ObId) of
        {'ok', 'answered'} ->
            lager:debug("Channel already answered"),
            gen_listener:cast(self(), 'channel_answered');
        _ -> 'ok'
    end,
    Props = [{'callid', whapps_call:call_id(ObCall)}
            ,{'restrict_to'
            ,[<<"CHANNEL_DESTROY">>
             ,<<"CHANNEL_ANSWER">>]
            }],
    gen_listener:add_binding(self(), 'call', Props),
    {'noreply', State};

handle_cast({'outbound_call_hangup', HangupCause}, State) ->
    lager:info("Outbound call hang up, reason ~p", [HangupCause]),
    {'stop', {'shutdown', 'hangup'}, State#state{hangupcause=HangupCause
                                  ,hangup_tstamp=wh_util:current_tstamp()}};

handle_cast('init', State) ->
    #state{call=Call, myq=Q, conference=Conference} = State,
    put('callid', <<(wh_json:get_value(<<"_id">>, Conference))/binary, <<"-">>/binary, (whapps_call:to_user(Call))/binary>>),
    lager:debug("Initializing conference participant"),
    case outbound_call:start(Call) of
        {'ok', ObId, ObCall} ->
            gen_listener:cast(self(), 'outbound_call_originated'),
            {'noreply', State#state{obcall=whapps_call:set_controller_queue(Q, ObCall)
                                    ,obid=ObId, status='proceeding'}};
        {'error', _Reason} ->
            lager:error("Call conference participant failed, reason ~p", [_Reason]),
           {'stop', {'shutdown', 'originate_failed'}, State#state{status='failed'}};
        _Else ->
            lager:error("Outbound call returned unexpected ~p", [_Else]),
           {'stop', {'shutdown', 'originate_failed'}, State#state{status='failed'}}
    end;

handle_cast('stop', State) ->
    lager:debug("Stopping conference participant"),
    outbound_call:stop(State#state.obid),
    {'stop', 'shutdown', State};

handle_cast(_Cast, State) ->
    lager:info("Unhandled cast: ~p", [_Cast]),
    {'noreply', State}.

handle_event(JObj, State) ->
    #state{self=Pid} = State,
    case whapps_util:get_event_type(JObj) of
        {<<"call_event">>, <<"CHANNEL_DESTROY">>} ->
            HangupCause = wh_json:get_value(<<"Hangup-Cause">>, JObj, <<"unknown">>),
            gen_listener:cast(Pid, {'outbound_call_hangup', HangupCause});
        {<<"call_event">>, <<"CHANNEL_ANSWER">>} ->
            gen_listener:cast(Pid, 'channel_answered');
        _Else ->
            lager:info("Unhandled event ~p", [JObj])
    end,
    {'reply', []}.

is_final_state('initial') -> 'false';
is_final_state('proceeding') -> 'false';
is_final_state('online') -> 'false';
is_final_state(_) -> 'true'.

reason_to_final_state('normal') -> 'succeeded';
reason_to_final_state('shutdown') -> 'interrupted';
reason_to_final_state({'shutdown', _}) -> 'interrupted';
reason_to_final_state('hangup') -> 'offline';
reason_to_final_state('originate_failed') -> 'failed';
reason_to_final_state('moderator_exited') -> 'succeeded';
reason_to_final_state(_) -> 'exception'.

terminate({'shutdown', Reason}, State) ->
    #state{status=Status} = State,
    Call = case State#state.obcall of
        'undefined' -> State#state.call;
        _Else -> _Else
    end,
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
    gen_listener:cast(State#state.server, {'party_exited', PartyLog}),
    lager:info("Conference participatn terminated: ~p", [Reason]);
terminate(_, State) ->
    terminate({'shutdown', 'unknown'}, State).

code_change(_OldVsn, State, _Extra) ->
    {'ok', State}.

init([Server, Conference, Call]) ->
    {'ok', #state{conference=Conference
                 ,server=Server
                 ,self=self()
                 ,call=Call
                 ,status='initial'
                 ,start_tstamp=wh_util:current_tstamp()}
    }.
