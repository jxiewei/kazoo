-module(ob_conferences).

-behaviour(gen_listener).

-include_lib("whistle/include/wh_databases.hrl").
-include("conference.hrl").

%%API
-export([start_link/0
        ,get_server/1
        ,register_server/2
        ,unregister_server/1]).

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


start_link() ->
    Bindings = [{'self', []}],
    gen_listener:start_link(?MODULE, [{'responders', ?RESPONDERS}
                                      ,{'bindings', Bindings}
                                      ,{'queue_name', ?QUEUE_NAME}
                                      ,{'queue_options', ?QUEUE_OPTIONS}
                                      ,{'consume_options', ?CONSUME_OPTIONS}
                                     ], []).

register_server(ConferenceId, Srv) ->
    [Pid] = gproc:lookup_pids({'p', 'l', 'ob_conferences'}),
    gen_listener:cast(Pid, {'register_server', ConferenceId, Srv}),
    'ok'.

unregister_server(ConferenceId) ->
    [Pid] = gproc:lookup_pids({'p', 'l', 'ob_conferences'}),
    gen_listener:cast(Pid, {'unregister_server', ConferenceId}),
    'ok'.

get_server(ConferenceId) ->
    [Pid] = gproc:lookup_pids({'p', 'l', 'ob_conferences'}),
    gen_listener:call(Pid, {'get_server', ConferenceId}).

handle_info(_Msg, State) ->
    lager:debug("unhandled message: ~p", [_Msg]),
    {'noreply', State}.

handle_cast({'register_server', ConferenceId, Srv}, State) ->
    lager:info("register ob conference server(~p, ~p)", [ConferenceId, Srv]),
    {'noreply', dict:store(ConferenceId, Srv, State)};

handle_cast({'unregister_server', ConferenceId}, State) ->
    lager:info("unregister ob conference server(~p)", [ConferenceId]),
    {'noreply', dict:erase(ConferenceId, State)};

handle_cast({'gen_listener',{'is_consuming',_IsConsuming}}, State) ->
    {'noreply', State};

handle_cast({'gen_listener',{'created_queue',_QueueName}}, State) ->
    {'noreply', State};

handle_cast(_Cast, State) ->
    lager:debug("unhandled cast: ~p", [_Cast]),
    {'noreply', State}.

handle_call({'get_server', ConferenceId}, _From, State) ->
    case dict:find(ConferenceId, State) of
    {'ok', Srv} -> {'reply', {'ok', Srv}, State};
    _ -> {'reply', {'error', 'not_found'}, State}
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
    gproc:reg({'p', 'l', 'ob_conferences'}),
    {'ok', dict:new()}.
