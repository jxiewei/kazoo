-module(ob_conference_manager).

-behaviour(gen_listener).

-include_lib("whistle/include/wh_databases.hrl").
-include("conference.hrl").

%%API
-export([start_link/0
        ,start_conference/3
        ,stop_conference/1
        ,get_server/1]).

%%gen_server callbacks
-export([init/1
        ,handle_event/2
        ,handle_call/3
        ,handle_info/2
        ,handle_cast/2
        ,terminate/2
        ,code_change/3]).

-record(state, {conferences}).

-define('SERVER', ?MODULE).

-define(RESPONDERS, []).
-define(QUEUE_NAME, <<>>).
-define(QUEUE_OPTIONS, []).
-define(CONSUME_OPTIONS, []).

start_link() ->
    Bindings = [{'self', []}],
    gen_listener:start_link(?MODULE, [{'responders', ?RESPONDERS}
                                      ,{'bindings', Bindings}
                                      ,{'queue_name', ?QUEUE_NAME}
                                      ,{'queue_options', ?QUEUE_OPTIONS}
                                      ,{'consume_options', ?CONSUME_OPTIONS}
                                     ], []).

start_conference(AccountId, UserId, ConferenceId) -> 
    [Pid] = gproc:lookup_pids({'p', 'l', 'ob_conference_manager'}),
    gen_listener:call(Pid, {'start_conference', AccountId, UserId, ConferenceId}).

stop_conference(ConferenceId) ->
    [Pid] = gproc:lookup_pids({'p', 'l', 'ob_conference_manager'}),
    gen_listener:call(Pid, {'stop_conference', ConferenceId}).

get_server(ConferenceId) ->
    [Pid] = gproc:lookup_pids({'p', 'l', 'ob_conference_manager'}),
    gen_listener:call(Pid, {'get_server', ConferenceId}).

handle_info({'EXIT', Pid, {'shutdown', {ConferenceId, Reason}}}, State) ->
    lager:debug("Conference pid ~p id ~p exited: ~p", [Pid, ConferenceId, Reason]),
    #state{conferences=Conferences} = State,
    {'noreply', State#state{conferences=dict:erase(ConferenceId, Conferences)}};
    
handle_info({'EXIT', Pid, Reason}, State) ->
    lager:debug("Conference pid ~p exited: ~p", [Pid, Reason]),
    #state{conferences=Conferences} = State,
    Conferences1 = dict:filter(fun(_, V) -> V =/= Pid end, Conferences),
    {'noreply', State#state{conferences=Conferences1}};

handle_info(_Msg, State) ->
    lager:debug("unhandled message: ~p", [_Msg]),
    {'noreply', State}.

handle_cast({'gen_listener',{'is_consuming',_IsConsuming}}, State) ->
    {'noreply', State};

handle_cast({'gen_listener',{'created_queue',_QueueName}}, State) ->
    {'noreply', State};

handle_cast(_Cast, State) -> lager:debug("unhandled cast: ~p", [_Cast]), {'noreply', State}.

handle_call({'start_conference', AccountId, UserId, ConferenceId}, _From, State) ->
    #state{conferences=Conferences} = State,
    case dict:find(ConferenceId, Conferences) of
        {'ok', _Pid} ->
            lager:debug("Conference ~p already started", [ConferenceId]),
            {'reply', {'error', 'already_started'}, State};
        _ ->
            {'ok', Pid} = ob_conference:start_link(AccountId, UserId, ConferenceId),
            {'reply', 'ok', State#state{conferences=dict:store(ConferenceId, Pid, Conferences)}}
    end;

handle_call({'stop_conference', ConferenceId}, _From, State) ->
    #state{conferences=Conferences} = State,
    case dict:find(ConferenceId, Conferences) of
        {'ok', Pid} ->
            gen_listener:cast(Pid, 'stop');
        _Else ->
            lager:debug("Conference ~p already stopped", [ConferenceId])
    end,
    {'reply', 'ok', State};

handle_call({'get_server', ConferenceId}, _From, State) ->
    #state{conferences=Conferences} = State,
    case dict:find(ConferenceId, Conferences) of
        {'ok', Pid} ->
            {'reply', {'ok', Pid}, State};
        _Else ->
            {'reply', {'error', 'not_found'}, State}
    end;

handle_call(_Request, _, P) ->
    {'reply', {'error', 'unimplemented'}, P}.

handle_event(_JObj, _State) ->
    {'reply', []}.

terminate(_Reason, _State) ->
    lager:info("ob_conferences execution has been stopped: ~p", [_Reason]).

code_change(_OldVsn, State, _Extra) ->
    {'ok', State}.

init([]) ->
    process_flag('trap_exit', 'true'),
    gproc:reg({'p', 'l', 'ob_conference_manager'}),
    {'ok', #state{conferences=dict:new()}}.
