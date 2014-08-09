%%%-------------------------------------------------------------------
%%% @copyright (C) 2013, 2600Hz
%%% @doc
%%%
%%% @end
%%% @contributors
%%%-------------------------------------------------------------------
-module(outbound_call_manager).

-behaviour(gen_listener).

-export([start_link/0
        ,start/2, stop/1
        ,get_server/1]).
-export([init/1
         ,handle_call/3
         ,handle_cast/2
         ,handle_info/2
         ,handle_event/2
         ,terminate/2
         ,code_change/3
        ]).

-include("outbound.hrl").

-record(state, {calls}).

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

start(Endpoint, Call) ->
    [Pid] = gproc:lookup_pids({'p', 'l', 'outbound_call_manager'}),
    gen_listener:call(Pid, {'start', Endpoint, Call}).

stop(Id) ->
    [Pid] = gproc:lookup_pids({'p', 'l', 'outbound_call_manager'}),
    gen_listener:call(Pid, {'stop', Id}).

get_server(Id) ->
    [Pid] = gproc:lookup_pids({'p', 'l', 'outbound_call_manager'}),
    gen_listener:call(Pid, {'get_server', Id}).
    
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
    gproc:reg({'p', 'l', 'outbound_call_manager'}),
    Props = [{'restrict_to', [<<"CHANNEL_BRIDGE">>]}],
    gen_listener:add_binding(self(), 'call', Props),
    {'ok', #state{calls=dict:new()}}.

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

handle_call({'start', Endpoint, Call}, {FromPid, _}, State) ->
    #state{calls=Calls} = State,
    Id = wh_util:rand_hex_binary(16),
    {'ok', Pid} = outbound_call_sup:start(Id, Endpoint, Call, FromPid),
    {'reply', {'ok', Id}, State#state{calls=dict:store(Id, Pid, Calls)}};

handle_call({'stop', Id}, _, State) ->
    #state{calls=Calls} = State,
    case dict:find(Id, Calls) of
        {'ok', Pid} -> 
            gen_listener:cast(Pid, 'stop'),
            {'reply', 'ok', State#state{calls=dict:erase(Id, Calls)}};
        _ ->
            {'reply', {'error', 'not_found'}, State}
    end;

handle_call({'get_server', Id}, _From, State) ->
    #state{calls=Calls} = State,
    case dict:find(Id, Calls) of
        {'ok', Pid} ->
            {'reply', {'ok', Pid}, State};
        _ ->
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

handle_event(JObj, State) ->
    case whapps_util:get_event_type(JObj) of
        {<<"call_event">>, <<"CHANNEL_BRIDGE">>} ->
            Id = wh_json:get_value([<<"Custom-Channel-Vars">>, <<"OutBound-ID">>], JObj),
            case dict:find(Id, State#state.calls) of
                {'ok', Pid} -> gen_listener:cast(Pid, {'channel_bridged', JObj});
                _ -> 'ok'
            end;
        {_Else, _Info} ->
            lager:debug("received channel event ~p", [JObj])
    end,
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
    lager:debug("outbound_call_manager terminating: ~p", [_Reason]).

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
