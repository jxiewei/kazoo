-module(ob_conference).

-behaviour(gen_listener).

-include_lib("whistle/include/wh_databases.hrl").
-include("conference.hrl").

%%API
-export([start_link/3
        ,kickoff/3, status/1
        ,kick/2, stop/1
        ,stop/2, join/2]).

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
-define(EXIT_COND_CHECK_INTERVAL, 5).
-define(ORIGINATE_RATE, 10).

-record(state, {account_id :: binary() 
                ,userid :: binary()
                ,conferenceid :: binary()
                ,account :: wh_json:new() %Doc of request account
                ,user :: wh_json:new() %Doc of request user
                ,conference :: wh_json:new()
                ,parties
                ,self
                ,logid
                ,start_tstamp
                ,tref :: timer:tref()
               }).

-record(party, {pid, type, partylog}).

-record(tasklog, {
        logid
        ,conferenceid
        ,userid
        ,start_tstamp
        ,end_tstamp
        ,total_party
        ,success_party
        ,offline_party
        ,failed_party
        ,interrupted_party
        ,exception_party
        }).

start_link(AccountId, UserId, ConferenceId) ->
    Bindings = [{'self', []}],
    gen_listener:start_link(?MODULE, [{'responders', ?RESPONDERS}
                                      ,{'bindings', Bindings}
                                      ,{'queue_name', ?QUEUE_NAME}
                                      ,{'queue_options', ?QUEUE_OPTIONS}
                                      ,{'consume_options', ?CONSUME_OPTIONS}
                                     ], [AccountId, UserId, ConferenceId]).

kickoff(AccountId, UserId, ConferenceId) ->
    ob_conference_manager:start_conference(AccountId, UserId, ConferenceId).

kick(ConferenceId, Number) ->
    case ob_conference_manager:get_server(ConferenceId) of 
    {'ok', Srv} ->
        gen_listener:call(Srv, {'kick', Number});
    _ ->
        lager:info("ob_conference server for ~p not found", [ConferenceId]),
        'error'
    end.

stop(ConferenceId) ->
    ob_conference_manager:stop_conference(ConferenceId, 'normal').
stop(ConferenceId, Reason) ->
    ob_conference_manager:stop_conference(ConferenceId, Reason).

join(ConferenceId, Number) ->
    case ob_conference_manager:get_server(ConferenceId) of
    {'ok', Srv} ->
        gen_listener:call(Srv, {'join', Number});
    _ ->
        lager:info("ob_conference server for ~p not found", [ConferenceId]),
        'error'
    end.

status(ConferenceId) ->
    case ob_conference_manager:get_server(ConferenceId) of
    {'ok', Srv} ->
        gen_listener:call(Srv, {'status'});
    _ ->
        lager:info("ob_conference server for ~p not found", [ConferenceId]),
        'error'
    end.

handle_info('check_exit_condition', State) ->
    #state{conferenceid=ConferenceId, parties=Parties} = State,
    case lists:any(fun({_, #party{pid=Pid}}) ->
                        case Pid of
                            'undefined' -> 'false';
                            _ -> 'true'
                        end
                   end, dict:to_list(Parties)) of
        'true' ->
            lager:debug("Some participant still running"),
            {'noreply', State};
        'false' ->
            lager:info("No participant running, exiting conference task"),
            stop(ConferenceId, 'no_party'),
            {'noreply', State}
    end;

handle_info(_Msg, State) ->
    lager:info("unhandled message: ~p", [_Msg]),
    {'noreply', State}.

handle_cast('init', State) ->
    #state{conferenceid=ConferenceId, conference=Conference} = State,
    put('callid', ConferenceId),
    lager:debug("Initializing conference task ~p", [ConferenceId]),

    Moderators = wh_json:get_value([<<"moderator">>, <<"numbers">>], Conference),
    Members = wh_json:get_value([<<"member">>, <<"numbers">>], Conference),

    gen_listener:cast(self(), {'start_participant', moderator, Moderators}),
    gen_listener:cast(self(), {'start_participant', member, Members}),
    {'noreply', State};


handle_cast({'start_participant', _Type, []}, State) ->
    {'noreply', State};
handle_cast({'start_participant', _Type, [_Number|Others]},
                            #state{account_id=AccountId
                                ,account=Account
                                ,userid=UserId
                                ,user=User
                                ,conference=Conference
                                ,parties=Parties
                                }=State) ->

    Number = wh_util:to_binary(_Number),
    lager:debug("Starting conference participant ~p", [Number]),
    AccountDb = wh_util:format_account_id(AccountId, 'encoded'),
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

    {'ok', Pid} = ob_conf_participant:start(Conference, Call),
    timer:apply_after(wh_util:to_integer(1000/?ORIGINATE_RATE), gen_listener, cast, [self(), {'start_participant', _Type, Others}]),
    {'noreply', State#state{parties=dict:store(Number, #party{pid=Pid, type=_Type, partylog='undefined'}, Parties)}};

handle_cast({'party_exited', PartyLog}, State) ->
    Number = PartyLog#partylog.callee_id_number,
    #state{parties=Parties, logid=LogId
        ,userid=UserId, conference=Conference
        ,conferenceid=ConferenceId} = State,

    {'ok', Party} = dict:find(Number, Parties),
    case {Party#party.type, wh_json:is_false(<<"wait_for_moderator">>, Conference)} of
        {'moderator',  'true'} ->
            lager:debug("Moderator ~p exited and wait_for_moderator is false, stop conference now", [Number]),
            gen_listener:cast(self(), {'stop', 'moderator_exited'});
        _ -> 'ok'
    end,

    lager:debug("Party ~p exited, saving partylog", [Number]),
    PartyLog1 = PartyLog#partylog{tasklogid=LogId, owner_id=UserId},
    Parties1 = dict:store(Number, #party{pid='undefined', partylog=PartyLog1}, Parties),

    {'noreply', State#state{parties=Parties1}};

handle_cast({'stop', Reason='no_party'}, State) ->
    lager:debug("Stopping conference, reason is ~p", [Reason]),
    {'stop', {'shutdown', Reason}, State};

handle_cast({'stop', Reason}, State) ->
    lager:debug("Stopping conference, reason is ~p", [Reason]),
    #state{parties=Parties} = State,
    lists:foreach(
            fun({_, #party{pid=Pid}}) -> 
                case Pid of
                    'undefined' -> 'ok';
                    _ -> ob_conf_participant:stop(Pid, Reason) 
                end
            end, dict:to_list(Parties)),
    %% DO NOT stop now, have to wait for partylog from participants.
    {'noreply', State};


handle_cast({'gen_listener',{'is_consuming',_IsConsuming}}, State) ->
    {'noreply', State};

handle_cast({'gen_listener',{'created_queue',_QueueName}}, State) ->
    gen_listener:cast(self(), 'init'),
    {'noreply', State};

handle_cast(_Cast, State) ->
    lager:debug("unhandled cast: ~p", [_Cast]),
    {'noreply', State}.


handle_call({'kick', Number}, _From, State) ->
    lager:debug("kicking ~p out", [Number]),
    #state{parties=Parties} = State,
    case dict:find(Number, Parties) of
    {'ok', #party{pid=Pid}} -> 
        ob_conf_participant:stop(Pid),
        {'reply', 'ok', State};
    _ -> 
        {'reply', {'error', 'not_found'}, State}
    end;


handle_call({'join', Number}, _From, State) ->
    lager:debug("joining ~p into conference", [Number]),
    gen_listener:cast(self(), {'start_participant', member, Number}),
    {'reply', 'ok', State};

handle_call({'status'}, _From, State) ->
    #state{parties=Parties} = State,
    Acc0 = lists:foldl(fun({Number, #party{pid=Pid, partylog=PartyLog}}, Acc) ->
                    {'ok', Status} = case Pid of
                       'undefined' -> {'ok', PartyLog#partylog.final_state};
                       _ -> gen_listener:call(Pid, 'status')
                    end,
                    [{Number, Status}|Acc]
                end, [], dict:to_list(Parties)),
    {'reply', {'ok', Acc0}, State};

handle_call(_Request, _, P) ->
    {'reply', {'error', 'unimplemented'}, P}.

handle_event(JObj, _State) ->
    lager:debug("unhandled event ~p", [JObj]),
    {'reply', []}.

inc(Number) -> Number+1.
get_stats(Parties) ->
    Acc0 = dict:from_list(
            [{'succeeded', 0}
            ,{'offline', 0}
            ,{'failed', 0}
            ,{'interrupted', 0}
            ,{'exception', 0}
            ,{'total', 0}
            ]),

    dict:fold(fun(_, #party{partylog=PartyLog}, Acc) ->
                    Acc1 = dict:update('total', fun inc/1, Acc),
                    dict:update(PartyLog#partylog.final_state, fun inc/1, Acc1)
                end, Acc0, Parties).

save_tasklog(AccountId, TaskLog) ->
    lager:debug("Saving tasklog"),
    #tasklog{logid=LogId, conferenceid=ConferenceId
            ,start_tstamp=StartTs, end_tstamp=EndTs
            ,total_party=Total, success_party=Success
            ,offline_party=Offline, failed_party=Failed
            ,interrupted_party=Interrupted, exception_party=Exception
            ,userid=UserId
            } = TaskLog,

    AccountModb = wh_util:format_account_mod_id(AccountId),
    HistoryItem = wh_doc:update_pvt_parameters(
                    wh_json:from_list(
                        [{<<"_id">>, LogId}
                        ,{<<"conference_id">>, ConferenceId}
                        ,{<<"start_tsamp">>, StartTs}
                        ,{<<"end_tstamp">>, EndTs}
                        ,{<<"total_count">>, Total}
                        ,{<<"success_count">>, Success}
                        ,{<<"offline_count">>, Offline}
                        ,{<<"failed_count">>, Failed}
                        ,{<<"interrupted_count">>, Interrupted}
                        ,{<<"exception_count">>, Exception}
                        ,{<<"owner_id">>, UserId}
                        ]
                    )
                    ,AccountModb
                    ,[{'account_id', AccountId}
                    ,{'type', <<"conference_tasklog">>}
                   ]),
    {'ok', _} = kazoo_modb:save_doc(AccountId, HistoryItem).

save_partylog(AccountId, PartyLog) ->
    lager:debug("Saving partylog"),
    #partylog{
        tasklogid=TaskLogId
        ,call_id=CallId
        ,caller_id_number=CallerNumber
        ,callee_id_number=CalleeNumber
        ,start_tstamp=StartTs
        ,end_tstamp=EndTs
        ,answer_tstamp=AnswerTs
        ,hangup_tstamp=HangupTs
        ,final_state=FinalState
        ,hangup_cause=HangupCause
        ,owner_id=OwnerId
    } = PartyLog,

    AccountModb = wh_util:format_account_mod_id(AccountId),
    HistoryItem = wh_doc:update_pvt_parameters(
                    wh_json:from_list(
                        [{<<"pvt_tasklog_id">>, TaskLogId}
                        ,{<<"call_id">>, CallId}
                        ,{<<"callee_id_number">>, CalleeNumber}
                        ,{<<"caller_id_number">>, CallerNumber}
                        ,{<<"start_tstamp">>, StartTs}
                        ,{<<"end_tstamp">>, EndTs}
                        ,{<<"answer_tstamp">>, AnswerTs}
                        ,{<<"hangup_tstamp">>, HangupTs}
                        ,{<<"status">>, FinalState}
                        ,{<<"hangup_cause">>, HangupCause}
                        ,{<<"owner_id">>, OwnerId}
                        ]
                    )
                    ,AccountModb
                    ,[{'account_id', AccountId}
                    ,{'type', <<"conference_partylog">>}
                   ]),
    {'ok', _} = kazoo_modb:save_doc(AccountId, HistoryItem).

terminate(_Reason, State) ->
    lager:debug("Terminating conference task"),
    #state{account_id=AccountId, logid=LogId, conferenceid=ConferenceId, parties=Parties} = State,
    Stats = get_stats(Parties),

    TaskLog = #tasklog{
        logid=LogId
        ,conferenceid=ConferenceId
        ,userid=State#state.userid
        ,start_tstamp=State#state.start_tstamp
        ,end_tstamp=wh_util:current_tstamp()
        ,total_party=dict:fetch('total', Stats)
        ,success_party=dict:fetch('succeeded', Stats)
        ,offline_party=dict:fetch('offline', Stats)
        ,failed_party=dict:fetch('failed', Stats)
        ,interrupted_party=dict:fetch('interrupted', Stats)
        ,exception_party=dict:fetch('exception', Stats)
    },

    lager:debug("Saving tasklog and partylog"),
    save_tasklog(AccountId, TaskLog),
    dict:fold(fun(_, #party{partylog=PartyLog}, Acc) ->
            save_partylog(AccountId, PartyLog),
            Acc
           end, 'ok', Parties),

    lager:info("conference task has been stopped: ~p", [_Reason]).

code_change(_OldVsn, ObConf, _Extra) ->
    {'ok', ObConf}.

init([AccountId, UserId, ConferenceId]) ->
    process_flag('trap_exit', 'true'),
    AccountDb = wh_util:format_account_id(AccountId, 'encoded'),
    {'ok', AccountDoc} = couch_mgr:open_cache_doc(?WH_ACCOUNTS_DB, AccountId),
    {'ok', UserDoc} = couch_mgr:open_cache_doc(AccountDb, UserId),
    {'ok', ConferenceDoc} = couch_mgr:open_cache_doc(AccountDb, ConferenceId),
    {'ok', TRef} = timer:send_interval(timer:seconds(?EXIT_COND_CHECK_INTERVAL), 'check_exit_condition'),

    {'ok', #state{account_id=AccountId
                       ,userid=UserId
                       ,conferenceid=ConferenceId
                       ,account=AccountDoc
                       ,user=UserDoc
                       ,conference=ConferenceDoc
                       ,parties=dict:new()
                       ,self=self()
                       ,tref=TRef
                       ,logid=wh_util:rand_hex_binary(16)
                       ,start_tstamp=wh_util:current_tstamp()
                      }}.
