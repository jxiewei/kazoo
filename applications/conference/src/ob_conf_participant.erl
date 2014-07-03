-module(ob_conf_participant).

-behaviour(gen_listener).

-include_lib("whistle/include/wh_databases.hrl").
-include("conference.hrl").

%%API
-export([start_link/4]).

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

-record(state, {oid :: binary()
               ,conference :: whapps_conference:conference()
               ,myq :: binary()
               ,de
               ,call = whapps_call:call()
               ,control_q
               ,server :: pid()
               ,self :: pid()
               }).
start_link(Server, Conference, OID, Call) ->
    Bindings = [{'self', []}],
    gen_listener:start_link(?MODULE, [{'responders', ?RESPONDERS}
                                      ,{'bindings', Bindings}
                                      ,{'queue_name', ?QUEUE_NAME}
                                      ,{'queue_options', ?QUEUE_OPTIONS}
                                      ,{'consume_options', ?CONSUME_OPTIONS}
                                     ], [Server, Conference, OID, Call]).

handle_call(_Request, _, P) ->
    {'reply', {'error', 'unimplemented'}, P}.

handle_info(_Msg, State) ->
    lager:debug("unhandled message: ~p", [_Msg]),
    {'noreply', State}.

channel_answered(UUID) ->
    case whapps_util:amqp_pool_collect([{<<"Fields">>, [<<"Answered">>]}
                                        ,{<<"Call-ID">>, UUID}
                                        |wh_api:default_headers(?APP_NAME, ?APP_VERSION)
                                       ]
                                       ,fun wapi_call:publish_query_channels_req/1
                                       %,fun wapi_call:query_channels_resp_v/1
                                       ,{'ecallmgr', 'true'}
                                       ,20000)
    of
    {'ok', [Resp|_]} ->
        {'ok', wh_json:get_value([<<"Channels">>, UUID, <<"Answered">>], Resp)};
    _R ->
        lager:debug("jerry -- failed to get channel information ~p", [_R]),
        {'error'}
    end.



channel_control_queue(UUID) ->
    Req = [{<<"Call-ID">>, wh_util:to_binary(UUID)}
           | wh_api:default_headers(<<"shell">>, <<"0">>)
          ],
    case whapps_util:amqp_pool_request(Req
                                       ,fun wapi_call:publish_channel_status_req/1
                                       ,fun wapi_call:channel_status_resp_v/1
                                      )
    of
        {'ok', Resp} ->
            lager:debug("jerry -- channel status ~p~n", [Resp]),
            wh_json:get_value(<<"Control-Queue">>, Resp);
        {'error', _E} ->
            lager:debug("jerry -- failed to get status of '~s': '~p'", [UUID, _E]),
            'undefined'
    end.


handle_cast({'set_callid', CallId}, State) ->
    lager:debug("jerry -- received set_callid message(callid ~p)", [CallId]),
    Call = State#state.call,

    CtrlQ = channel_control_queue(CallId),
    {'ok', Answered} = channel_answered(CallId),
    lager:debug("jerry -- control queue is ~p, answer state is ~p", [CtrlQ, Answered]),

    case CtrlQ of
    'undefined' ->
        lager:debug("jerry -- channel doesn't exist"),
        gen_listener:cast(self(), 'channel_destroyed');
    _ -> 'ok'
    end,

    case Answered of
    'true' ->
        Props = [{'callid', CallId},{'restrict_to', [<<"CHANNEL_DESTROY">>]}],
        gen_listener:add_binding(self(), 'call', Props),
        'ok' = gen_listener:cast(self(), 'channel_answered');
    _ ->
        Props = [{'callid', CallId},{'restrict_to', [<<"CHANNEL_ANSWER">>, <<"CHANNEL_DESTROY">>]}],
        gen_listener:add_binding(self(), 'call', Props)
    end,
    {'noreply', State#state{call=whapps_call:set_call_id(CallId, Call), control_q=CtrlQ}};

handle_cast('channel_answered', State) ->
    Call = State#state.call,
    CtrlQ = State#state.control_q,
    CallId = whapps_call:call_id(Call),

    put('callid', CallId),
    lager:debug("jerry -- join (call ~p) to conference~n", [Call]),

    Updaters = [fun(C) -> whapps_call:set_control_queue(CtrlQ, C) end,
                fun(C) -> whapps_call:set_controller_queue(State#state.myq, C) end ],
    NewCall = lists:foldr(fun(F, C) -> F(C) end, Call, Updaters),

    lager:debug("jerry -- starting conf_participant(~p)~n", [NewCall]),

    whapps_call_command:prompt(<<"conf-welcome">>, NewCall),
    {'ok', Srv} = conf_participant_sup:start_participant(NewCall),
    conf_participant:set_discovery_event(State#state.de, Srv),
    %conf_participant:consume_call_events(Srv),
    conf_discovery_req:search_for_conference(
            whapps_conference:from_conference_doc(State#state.conference),
            NewCall, Srv),

    %%FIXME: store Call to calls
    {'noreply', State};

handle_cast('channel_destroyed', State) ->
    lager:debug("jerry -- channel destroyed, terminating"),
    gen_listener:cast(State#state.server, {'channel_destroyed', State#state.oid}),
    {'stop', {'shutdown', 'hangup'}, State};

handle_cast({'gen_listener',{'is_consuming',_IsConsuming}}, State) ->
    {'noreply', State};

handle_cast({'gen_listener',{'created_queue',_QueueName}}, State) ->
    DE = wh_json:from_list([{<<"Server-ID">>, _QueueName}
                           ,{<<"Conference-Doc">>, State#state.conference}]),
    {'noreply', State#state{myq=_QueueName, de=DE}};

handle_cast(_Cast, State) ->
    lager:debug("jerry -- unhandled cast: ~p", [_Cast]),
    {'noreply', State}.

handle_event(JObj, State) ->
    case whapps_util:get_event_type(JObj)  of
    {<<"call_event">>, <<"CHANNEL_ANSWER">>} ->
            lager:debug("jerry -- received channel answer event ~p~n", [JObj]),
            CallId = wh_json:get_value(<<"Call-ID">>, JObj),
            'true' = (CallId =:= whapps_call:call_id(State#state.call)),
            lager:debug("jerry -- call found"),
            'ok' = gen_listener:cast(State#state.self, 'channel_answered');
    {<<"call_event">>, <<"CHANNEL_DESTROY">>} ->
            lager:debug("jerry -- received channel destroy event ~p~n", [JObj]),
            CallId = wh_json:get_value(<<"Call-ID">>, JObj),
            'true' = (CallId =:= whapps_call:call_id(State#state.call)),
            lager:debug("jerry -- call found"),
            gen_listener:cast(State#state.self, 'channel_destroyed');
    {_Else, _Info} ->
            lager:debug("jerry -- received channel event ~p~n", [JObj])
    end,
    {'reply', []}.

terminate(_Reason, _State) ->
    lager:debug("ob_conference execution has been stopped: ~p", [_Reason]).

code_change(_OldVsn, State, _Extra) ->
    {'ok', State}.

init([Server, Conference, OID, Call]) ->
    {'ok', #state{oid=OID, 
                conference=Conference, 
                server=Server, 
                self=self(),
                call=Call}}.
