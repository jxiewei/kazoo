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

-record(state, {account_id :: binary()
                ,userid :: binary()
                ,taskid :: binary()
                ,account :: wh_json:new() %Doc of request account
                ,user :: wh_json:new() %Doc of request user
                ,task :: wh_json:new()
                ,participants :: dict:new()
                ,tref :: timer:tref() %check_exit_condition timer
                ,self :: pid()
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

is_terminated('initial') -> 'false';
is_terminated('proceeding') -> 'false';
is_terminated('online') -> 'false';
is_terminated(_) -> 'true'.

handle_info('check_exit_condition', State) ->
    #state{taskid=TaskId} = State,
    case lists:any(fun({_, Pid}) -> 
                       {'ok', Status} = broadcast_participant:status(Pid),
                       not is_terminated(Status) end,
                   dict:to_list(State#state.participants)) of
        'true' -> 
            lager:debug("Some participant still running");
        'false' ->
            lager:info("No participant running, exiting broadcast task ~p", [TaskId]),
            broadcast_manager:del_task(TaskId)
    end,
    {'noreply', State};

handle_info(_Msg, State) ->
    lager:info("unhandled message: ~p", [_Msg]),
    {'noreply', State}.

handle_cast('init', State) ->
    #state{taskid=TaskId} = State,
    put('callid', TaskId),
    lager:debug("Initializing broadcast task ~p", [TaskId]),
    #state{task=Task} = State,
    
    Moderators = wh_json:get_value(<<"presenters">>, Task),
    Members = wh_json:get_value(<<"listeners">>, Task),
    lager:debug("presenters ~p, listeners ~p", [Moderators, Members]),
    lists:foreach(fun(N) ->
                    gen_listener:cast(self(), {'start_participant', wh_util:to_binary(N)}) 
                  end, Moderators ++ Members),

    {'noreply', State};

handle_cast({'start_participant', Number}, #state{account_id=AccountId
                                            ,account=Account
                                            ,userid=UserId
                                            ,user=User
                                            ,participants=Participants
                                            ,task=Task
                                            ,taskid=TaskId
                                            }=State) ->

    lager:debug("Starting broadcast participant ~p of task ~p", [Number, TaskId]),
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
               ,fun(C) -> whapps_call:set_owner_id(UserId, C) end]
               ,whapps_call:new()),

    {'ok', Pid} = broadcast_participant:start(Call, wh_json:get_value(<<"media_id">>, Task)),
    {'noreply', State#state{participants=dict:store(Number, Pid, Participants)}};

handle_cast({'gen_listener',{'is_consuming',_IsConsuming}}, State) ->
    {'noreply', State};

handle_cast({'gen_listener',{'created_queue',_QueueName}}, State) ->
    gen_listener:cast(self(), 'init'),
    {'noreply', State};

handle_cast('stop', State) ->
    #state{taskid=TaskId} = State,
    lager:debug("Stopping broadcast task ~p", [TaskId]),
    lists:foreach(fun({_, Pid}) -> broadcast_participant:stop(Pid) end, 
                  dict:to_list(State#state.participants)),
    {'stop', {'shutdown', 'stopped'}, State};

handle_cast(_Cast, State) ->
    lager:debug("unhandled cast: ~p", [_Cast]),
    {'noreply', State}.

handle_call('status', _From, State) ->
    Acc0 = lists:foldl(fun({Number, Pid}, Acc) ->
                    {'ok', Status} = gen_listener:call(Pid, 'status'),
                    [{Number, Status}|Acc] 
                end, [], dict:to_list(State#state.participants)),
    {'reply', {'ok', Acc0}, State};

handle_call(_Request, _, P) ->
    {'reply', {'error', 'unimplemented'}, P}.

handle_event(JObj, _State) ->
    lager:debug("unhandled event ~p", [JObj]),
    {'reply', []}.

terminate(_Reason, State) ->
    #state{taskid=TaskId} = State,
    lager:info("broadcast_task ~p execution has been stopped: ~p", [TaskId, _Reason]).

code_change(_OldVsn, State, _Extra) ->
    {'ok', State}.

init([AccountId, UserId, TaskId]) ->
    process_flag('trap_exit', 'true'),
    AccountDb = wh_util:format_account_id(AccountId, 'encoded'),
    {'ok', AccountDoc} = couch_mgr:open_cache_doc(?WH_ACCOUNTS_DB, AccountId),
    {'ok', UserDoc} = couch_mgr:open_cache_doc(AccountDb, UserId),
    {'ok', TaskDoc} = couch_mgr:open_cache_doc(AccountDb, TaskId),
    {'ok', TRef} = timer:send_interval(timer:seconds(?EXIT_COND_CHECK_INTERVAL), 'check_exit_condition'),

    {'ok', #state{account_id=AccountId
                    ,userid=UserId
                    ,taskid=TaskId
                    ,account=AccountDoc
                    ,user=UserDoc
                    ,task=TaskDoc
                    ,participants=dict:new()
                    ,tref=TRef
                    ,self=self()
                   }}.
