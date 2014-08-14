%%-------------------------------------------------------------------
%%% @copyright (C) 2013, 2600Hz
%%% @doc
%%%
%%% @end
%%% @contributors
%%%-------------------------------------------------------------------
-module(broadcast_manager).

-behaviour(gen_listener).

-export([start_link/0, init/1
        ,new_task/3, del_task/1
        ,get_server/1
        ,handle_call/3, handle_cast/2
        ,handle_info/2, handle_event/2
        ,terminate/2, code_change/3
        ,ecron_mfa/3
        ]).

-include("broadcast.hrl").

-record(state, {tasks}).

-define(BINDINGS, [{'self', []}
                  ]).
-define(RESPONDERS, []).
-define(QUEUE_NAME, <<"">>).
-define(QUEUE_OPTIONS, []).
-define(CONSUME_OPTIONS, []).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link() ->
    gen_listener:start_link(?MODULE, [{'bindings', ?BINDINGS}
                                      ,{'responders', ?RESPONDERS}
                                      ,{'queue_name', ?QUEUE_NAME}
                                      ,{'queue_options', ?QUEUE_OPTIONS}
                                      ,{'consume_options', ?CONSUME_OPTIONS}
                                     ], []).


new_task(AccountId, UserId, TaskId) ->
    [Pid] = gproc:lookup_pids({'p', 'l', 'broadcast_manager'}),
    AccountDb = wh_util:format_account_id(AccountId, 'encoded'),
    {'ok', TaskDoc} = couch_mgr:open_cache_doc(AccountDb, TaskId),
    Scheduler = wh_json:get_integer_value(<<"scheduler">>, TaskDoc),
    lager:debug("Creating task, scheduler ~p, taskid ~p", [Scheduler, TaskId]),
    gen_listener:call(Pid, {'new_task', Scheduler, AccountId, UserId, TaskId}).

del_task(TaskId) ->
    [Pid] = gproc:lookup_pids({'p', 'l', 'broadcast_manager'}),
    gen_listener:call(Pid, {'del_task', TaskId}).

get_server(TaskId) ->
    [Pid] = gproc:lookup_pids({'p', 'l', 'broadcast_manager'}),
    gen_listener:call(Pid, {'get_server', TaskId}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([]) ->
    process_flag('trap_exit', 'true'),
    gproc:reg({'p', 'l', 'broadcast_manager'}),
    {'ok', #state{tasks=dict:new()}}.

ecron_mfa(AccountId, UserId, TaskId) ->
    lager:debug("In ecron_mfa"),
    [Pid] = gproc:lookup_pids({'p', 'l', 'broadcast_manager'}),
    gen_listener:call(Pid, {'new_task', 0, AccountId, UserId, TaskId}).

normalize_field(<<"*">>) -> '*';
normalize_field(Value) -> wh_util:to_integer(Value).


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------

handle_call({'new_task', 0, AccountId, UserId, TaskId}, _From, State) ->
    #state{tasks=Tasks} = State,
    case dict:find(TaskId, Tasks) of
        {'ok', _Pid} -> 
            lager:debug("Broadcast task ~p already started", [TaskId]),
            {'reply', {'error', 'already_started'}, State};
        _ -> 
            {'ok', Pid} = broadcast_task:start_link(AccountId, UserId, TaskId),
            {'reply', 'ok', State#state{tasks=dict:store(TaskId, Pid, Tasks)}}
    end;

handle_call({'new_task', 1, AccountId, UserId, TaskId}, _From, State) ->
    AccountDb = wh_util:format_account_id(AccountId, 'encoded'),
    {'ok', TaskDoc} = couch_mgr:open_cache_doc(AccountDb, TaskId),
    Arg = wh_json:get_value(<<"schedulerarg">>, TaskDoc),
    [Part1, Part2] = binary:split(Arg, <<" ">>),
    [Y,Mo,D] = binary:split(Part1, <<"-">>, [global]),
    [H,Mi,S] = binary:split(Part2, <<":">>, [global]),

    Date = {wh_util:to_integer(Y), wh_util:to_integer(Mo), wh_util:to_integer(D)},
    Time = {wh_util:to_integer(H), wh_util:to_integer(Mi), wh_util:to_integer(S)},
    case ecron:insert({Date, Time}, {?MODULE, ecron_mfa, [AccountId, UserId, TaskId]}) of
        'ok' -> 
            lager:debug("Create ecron entry successfully"),
            {'reply', 'ok', State};
        {'error', Reason} ->
            lager:debug("Create ecron entry failed, reason is ~p", [Reason]),
            {'reply', {'error', <<"Create cron entry failed, ", (wh_util:to_binary(Reason))/binary>>}, State}
    end;


handle_call({'new_task', 2, AccountId, UserId, TaskId}, _From, State) ->
    AccountDb = wh_util:format_account_id(AccountId, 'encoded'),
    {'ok', TaskDoc} = couch_mgr:open_cache_doc(AccountDb, TaskId),
    Arg = wh_json:get_value(<<"schedulerarg">>, TaskDoc),
    Dom = normalize_field(wh_json:get_value(<<"DayOfMonth">>, Arg)),
    Dow = normalize_field(wh_json:get_value(<<"DayOfWeek">>, Arg)),
    Hour = wh_json:get_integer_value(<<"Hour">>, Arg),
    Minute = wh_json:get_integer_value(<<"Minute">>, Arg),

    lager:debug("Creating ecron entry ~p", [{{'*', '*', Dom, Dow}, {Hour, Minute, 0}}]),
    case ecron:insert({{'*', '*', Dom, Dow}, {Hour, Minute, 0}}
                ,{?MODULE, ecron_mfa, [AccountId, UserId, TaskId]}) of
        'ok' -> 
            lager:debug("Create ecron entry successfully"),
            {'reply', 'ok', State};
        {'error', Reason} ->
            lager:debug("Create ecron entry failed, reason is ~p", [Reason]),
            {'reply', {'error', <<"Create cron entry failed, ", (wh_util:to_binary(Reason))/binary>>}, State}
    end;

handle_call({'del_task', TaskId}, _From, State) ->
    #state{tasks=Tasks} = State,

    lists:foreach(
            fun(Job) ->
                case Job of
                    {job, {_, Id}, {{_M, _F, [_AccountId, _UserId, TaskId]}, _}, _, _, _} -> 
                        ecron:delete(Id);
                    _ -> 
                        lager:debug("Job ~p", [Job])
                end
            end, ecron:list()),

    case dict:find(TaskId, Tasks) of
        {'ok', Pid} ->
            gen_listener:cast(Pid, 'stop'),
            {'reply', 'ok', State};
        _Else ->
            {'reply', 'ok', State}
    end;

handle_call({'get_server', TaskId}, _From, State) ->
    #state{tasks=Tasks} = State,
    case dict:find(TaskId, Tasks) of
        {'ok', Pid} ->
            {'reply', {'ok', Pid}, State};
        _Else ->
            {'reply', {'error', 'not_found'}, State}
    end;

handle_call(_Request, _From, State) ->
    {'reply', {'error', 'not_implemented'}, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast({'gen_listener', {'created_queue', _QueueNAme}}, State) ->
    {'noreply', State};

handle_cast({'gen_listener', {'is_consuming', _IsConsuming}}, State) ->
    {'noreply', State};

handle_cast(_Msg, State) ->
    {'noreply', State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------

handle_info({'EXIT', Pid, Reason}, State) ->
    lager:debug("Broadcast participant pid ~p exited: ~p", [Pid, Reason]),
    #state{tasks=Tasks} = State,
    Tasks1 = dict:filter(fun(_, V) -> V =/= Pid end, Tasks),
    {'noreply', State#state{tasks=Tasks1}};
handle_info(_Info, State) ->
    {'noreply', State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Allows listener to pass options to handlers
%%
%% @spec handle_event(JObj, State) -> {reply, Options}
%% @end
%%--------------------------------------------------------------------

handle_event(JObj, _State) ->
    lager:debug("jerry -- unhandled event ~p", [JObj]),
    {'reply', []}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    lager:debug("broadcast_manager terminating: ~p", [_Reason]).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {'ok', State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
