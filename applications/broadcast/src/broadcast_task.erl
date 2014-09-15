-module(broadcast_task).

-behaviour(gen_listener).

-include_lib("whistle/include/wh_databases.hrl").
-include("broadcast.hrl").

%%API
-export([start_link/3
        ,start/3
        ,status/1
        ,stop/1]).

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
-define(ORIGINATE_RATE, 20).

-record(state, {account_id :: binary()
                ,userid :: binary()
                ,taskid :: binary()
                ,account :: wh_json:new() %Doc of request account
                ,user :: wh_json:new() %Doc of request user
                ,task :: wh_json:new()
                ,tasktype :: atom()
                ,participants :: dict:new()
                ,tref :: timer:tref() %check_exit_condition timer
                ,self :: pid()
                ,logid
                ,start_tstamp
                ,end_tstamp
                ,recordingpid
                ,recordid
               }).

-record(participant, {pid, partylog}).

-record(tasklog, {
        logid
        ,taskid
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


start_link(AccountId, UserId, TaskId) ->
    Bindings = [{'self', []}],
    gen_listener:start_link(?MODULE, [{'responders', ?RESPONDERS}
                                      ,{'bindings', Bindings}
                                      ,{'queue_name', ?QUEUE_NAME}
                                      ,{'queue_options', ?QUEUE_OPTIONS}
                                      ,{'consume_options', ?CONSUME_OPTIONS}
                                     ], [AccountId, UserId, TaskId]).

start(AccountId, UserId, TaskId) ->
    broadcast_manager:new_task(AccountId, UserId, TaskId).

status(TaskId) ->
    case broadcast_manager:get_server(TaskId) of
    {'ok', Pid} ->
        gen_listener:call(Pid, 'status');
    _Else ->
        lager:info("broadcast server for ~p not found", [TaskId]),
        _Else
    end.

stop(TaskId) ->
    broadcast_manager:del_task(TaskId).

handle_info('check_exit_condition', State) ->
    #state{participants=Parties} = State,
    %case lists:any(fun({_, #participant{pid=Pid}}) -> 
    case lists:any(fun({_, #participant{pid=Pid}}) -> 
                        case Pid of
                            'undefined' -> 'false';
                            _ -> 'true'
                        end
                   end, dict:to_list(Parties)) of
        'true' -> 
            lager:debug("Some participant still running"),
            {'noreply', State};
        'false' ->
            lager:info("No participant running, exiting broadcast task"),
            {'stop', 'shutdown', State}
    end;

handle_info({'EXIT', Pid, Reason}, #state{recordingpid=Pid} = State) ->
    lager:debug("recoridng process ~p exited: ~p", [Pid, Reason]),
    {'noreply', State};

handle_info(_Msg, State) ->
    lager:info("unhandled message: ~p", [_Msg]),
    {'noreply', State}.

handle_cast('init', State) ->
    #state{tasktype=TaskType, taskid=TaskId} = State,
    put('callid', TaskId),
    lager:debug("Initializing broadcast task ~p", [TaskId]),
    case TaskType of
        'file' -> gen_listener:cast(self(), 'start_broadcast');
        'conference' -> gen_listener:cast(self(), 'start_broadcast');
        'recording' -> gen_listener:cast(self(), 'start_recording')
    end,
    {'noreply', State};

handle_cast('start_recording', State) ->
    #state{account=Account, user=User, task=Task} = State,
    [Number|_] = wh_json:get_ne_value(<<"presenters">>, Task, []),
    Call = broadcast_util:create_call(Account, User, Task, Number),
    {'ok', RecordingPid} = broadcast_recording:start(Call),
    link(RecordingPid),
    {'noreply', State#state{recordingpid=RecordingPid}};

handle_cast({'recording_complete', Id}, State) ->
    case Id of
        'undefined' -> 
            {'stop', 'shutdown', State};
        _ ->
            gen_listener:cast(self(), 'start_broadcast'),
            {'noreply', State#state{recordid=Id}}
    end;

handle_cast('start_broadcast', #state{tasktype='recording'} = State) ->
    #state{taskid=TaskId, task=Task} = State,
    lager:debug("Starting broadcast ~p", [TaskId]),

    Members = wh_json:get_ne_value(<<"listeners">>, Task, []),
    lager:debug("listeners ~p", [Members]),

    Parties = [{'false', Number}||Number <- Members],
    gen_listener:cast(self(), {'start_participant', Parties}),

    {'ok', TRef} = timer:send_interval(timer:seconds(?EXIT_COND_CHECK_INTERVAL), 'check_exit_condition'),
    {'noreply', State#state{tref=TRef}};

handle_cast('start_broadcast', State) ->
    #state{task=Task} = State,

    Moderators = wh_json:get_ne_value(<<"presenters">>, Task, []),
    Members = wh_json:get_ne_value(<<"listeners">>, Task, []),
    lager:debug("presenters ~p, listeners ~p", [Moderators, Members]),

    Parties = [{'true', Number}||Number <- Moderators] ++ 
            [{'false', Number}||Number <- Members],

    %%Reverse it to make sure moderator is joined to conference at last.
    gen_listener:cast(self(), {'start_participant', lists:reverse(Parties)}),

    {'ok', TRef} = timer:send_interval(timer:seconds(?EXIT_COND_CHECK_INTERVAL), 'check_exit_condition'),
    {'noreply', State#state{tref=TRef}};


handle_cast({'start_participant', []}, State) -> {'noreply', State};
handle_cast({'start_participant', [{Moderator, Number}|Others]}, 
                                    #state{account=Account
                                           ,user=User
                                           ,task=Task
                                           ,taskid=TaskId
                                           ,tasktype=TaskType
                                           ,participants=Parties
                                           ,recordid=RecordId
                                          }=State) ->

    lager:debug("Starting broadcast participant ~p of task ~p", [Number, TaskId]),
    Call = broadcast_util:create_call(Account, User, Task, Number),

    case TaskType of
        'file' ->
            {'ok', Pid} = broadcast_participant:start(Call, {TaskType, Moderator, wh_json:get_value(<<"media_id">>, Task)});
        'recording' ->
            {'ok', Pid} = broadcast_participant:start(Call, {TaskType, Moderator, RecordId});
        'conference' ->
            {'ok', Pid} = broadcast_participant:start(Call, {TaskType, Moderator, TaskId})
    end,
    timer:apply_after(wh_util:to_integer(1000/?ORIGINATE_RATE), gen_listener, cast, [self(), {'start_participant', Others}]),
    {'noreply', State#state{participants=dict:store(Number, #participant{pid=Pid, partylog=#partylog{}}, Parties)}};

handle_cast({'participant_exited', PartyLog}, State) ->
    lager:debug("Participant exited, saving partylog"),
    #state{participants=Parties, logid=LogId, userid=UserId} = State,
    PartyLog1 = PartyLog#partylog{tasklogid=LogId, owner_id=UserId},
    Parties1 = dict:store(PartyLog#partylog.callee_id_number, #participant{pid='undefined', partylog=PartyLog1}, Parties),
    {'noreply', State#state{participants=Parties1}};

handle_cast({'gen_listener',{'is_consuming',_IsConsuming}}, State) ->
    {'noreply', State};

handle_cast({'gen_listener',{'created_queue',_QueueName}}, State) ->
    gen_listener:cast(self(), 'init'),
    {'noreply', State};

handle_cast('stop', State) ->
    #state{taskid=TaskId} = State,
    lager:debug("Stopping broadcast task ~p", [TaskId]),
    lists:foreach(
            fun({_, #participant{pid=Pid}}) -> 
                case Pid of
                    'undefined' -> 'ok';
                    _ -> broadcast_participant:stop(Pid) 
                end
            end, dict:to_list(State#state.participants)),

    {'noreply', State};

handle_cast(_Cast, State) ->
    lager:debug("unhandled cast: ~p", [_Cast]),
    {'noreply', State}.

handle_call('status', _From, State) ->
    Acc0 = lists:foldl(fun({Number, #participant{pid=Pid, partylog=PartyLog}}, Acc) ->
                    {'ok', Status} = case Pid of
                       'undefined' -> {'ok', PartyLog#partylog.final_state};
                       _ -> gen_listener:call(Pid, 'status')
                    end,
                    [{Number, Status}|Acc] 
                end, [], dict:to_list(State#state.participants)),
    {'reply', {'ok', Acc0}, State};

handle_call(_Request, _, P) ->
    {'reply', {'error', 'unimplemented'}, P}.

handle_event(JObj, _State) ->
    lager:debug("unhandled event ~p", [JObj]),
    {'reply', []}.

%% {total_party, success_party, offline_party, failed_party, 
%%  interrupted_party, exception_party}

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

    dict:fold(fun(_, #participant{partylog=PartyLog}, Acc) ->
                    Acc1 = dict:update('total', fun inc/1, Acc),
                    dict:update(PartyLog#partylog.final_state, fun inc/1, Acc1)
                end, Acc0, Parties).

save_tasklog(AccountId, TaskLog) ->
    lager:debug("Saving tasklog"),
    #tasklog{logid=LogId, taskid=TaskId
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
                        ,{<<"task_id">>, TaskId}
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
                    ,{'type', <<"broadcast_tasklog">>}
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
                    ,{'type', <<"broadcast_partylog">>}
                   ]),
    {'ok', _} = kazoo_modb:save_doc(AccountId, HistoryItem).


terminate(_Reason, State) ->
    lager:debug("Terminating broadcast task"),
    #state{account_id=AccountId, logid=LogId, taskid=TaskId, participants=Parties} = State,
    Stats = get_stats(Parties),

    TaskLog = #tasklog{
        logid=LogId
        ,taskid=TaskId
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
    dict:fold(fun(_, #participant{partylog=PartyLog}, Acc) -> 
            save_partylog(AccountId, PartyLog), 
            Acc
           end, 'ok', Parties), 

    lager:info("broadcast_task has been stopped: ~p", [_Reason]).

code_change(_OldVsn, State, _Extra) ->
    {'ok', State}.

init([AccountId, UserId, TaskId]) ->
    process_flag('trap_exit', 'true'),
    AccountDb = wh_util:format_account_id(AccountId, 'encoded'),
    {'ok', AccountDoc} = couch_mgr:open_cache_doc(?WH_ACCOUNTS_DB, AccountId),
    {'ok', UserDoc} = couch_mgr:open_cache_doc(AccountDb, UserId),
    {'ok', TaskDoc} = couch_mgr:open_cache_doc(AccountDb, TaskId),
    Type = wh_util:to_atom(wh_json:get_value(<<"type">>, TaskDoc)),

    {'ok', #state{account_id=AccountId
                    ,userid=UserId
                    ,taskid=TaskId
                    ,account=AccountDoc
                    ,user=UserDoc
                    ,task=TaskDoc
                    ,tasktype=Type
                    ,participants=dict:new()
                    ,self=self()
                    ,logid=wh_util:rand_hex_binary(16)
                    ,start_tstamp=wh_util:current_tstamp()
                   }}.

