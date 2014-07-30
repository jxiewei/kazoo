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
               }).

start(Call, Media) ->
    Bindings = [{'self', []}],
    gen_listener:start_link(?MODULE, [{'responders', ?RESPONDERS}
                                      ,{'bindings', Bindings} ,{'queue_name', ?QUEUE_NAME}
                                      ,{'queue_options', ?QUEUE_OPTIONS}
                                      ,{'consume_options', ?CONSUME_OPTIONS}
                                     ], [Call, Media]).

stop(Pid) ->
    gen_listener:cast(Pid, 'stop').

status(Pid) ->
    gen_listener:call(Pid, 'status').

handle_call(_Request, _From, #state{status=Status}=State) ->
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
    {'noreply', State#state{status='online'}};

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

handle_cast('outbound_call_hangup', State) ->
    lager:debug("Broadcast participant call hanged up"),
    {'noreply', State#state{status='offline'}};

handle_cast('play_completed', State) ->
    lager:debug("Finished playing to broadcast participant"),
    outbound_call:stop(State#state.obid),
    {'noreply', State#state{status='succeed'}};

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

handle_event(JObj, State) ->
    #state{self=Pid} = State,
    case whapps_util:get_event_type(JObj) of
        {<<"call_event">>, <<"CHANNEL_EXECUTE_COMPLETE">>} ->
            gen_listener:cast(Pid, 'play_completed');
        {<<"call_event">>, <<"CHANNEL_DESTROY">>} ->
            gen_listener:cast(Pid, 'outbound_call_hangup');
        {<<"call_event">>, <<"CHANNEL_ANSWER">>} ->
            gen_listener:cast(Pid, 'channel_answered');
        _Else ->
            lager:debug("jerry -- unhandled event ~p", [JObj])
    end,
    {'reply', []}.

terminate(_Reason, _State) ->
    lager:info("broadcast_participant execution has been stopped: ~p", [_Reason]).

code_change(_OldVsn, State, _Extra) ->
    {'ok', State}.

init([Call, Media]) ->
    {'ok', #state{call=Call
                 ,media=Media
                 ,self=self()
                 ,status='initial'}
    }.
