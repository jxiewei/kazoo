
-module(broadcast_recording).

-behaviour(gen_listener).

-include_lib("whistle/include/wh_databases.hrl").
-include("broadcast.hrl").

%%API
-export([start/1
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

-record(state, {call :: whapps_call:call()
               ,status
               ,self :: pid()
               ,myq
               ,server :: pid()
               ,recordid
               }).


start(Call) ->
    Bindings = [{'self', []}],
    gen_listener:start_link(?MODULE, [{'responders', ?RESPONDERS}
                                      ,{'bindings', Bindings} ,{'queue_name', ?QUEUE_NAME}
                                      ,{'queue_options', ?QUEUE_OPTIONS}
                                      ,{'consume_options', ?CONSUME_OPTIONS}
                                     ], [self(), Call]).

stop(Pid) ->
    gen_listener:cast(Pid, 'stop').

handle_call(_Request, _From, State) ->
    {'reply', {'error', 'unimplemented'}, State}.

handle_info(_Msg, State) ->
    lager:debug("unhandled message: ~p", [_Msg]),
    {'noreply', State}.

handle_cast({'gen_listener',{'is_consuming',_IsConsuming}}, State) ->
    {'noreply', State};

handle_cast({'gen_listener',{'created_queue',_QueueName}}, State) ->
    #state{call=Call} = State,
    gen_listener:cast(self(), 'init'),
    {'noreply', State#state{call=whapps_call:kvs_store('consumer_pid', self(), Call)
                           ,myq=_QueueName}};

handle_cast('answered', State) ->
    #state{call=Call} = State,
    lager:debug("Broadcast presenter answered"),
    broadcast_util:start_recording(Call),
    {'noreply', State#state{status='recording'}};

handle_cast({'originate_ready', JObj}, State) ->
    #state{call=Call, myq=Q} = State,
    CtrlQ = wh_json:get_value(<<"Control-Queue">>, JObj),
    Props = [{'callid', whapps_call:call_id(Call)}
                ,{'restrict_to'
                ,[<<"CHANNEL_DESTROY">>
                ,<<"CHANNEL_ANSWER">>]
                }],
    gen_listener:add_binding(self(), 'call', Props),
    send_originate_execute(JObj, Q),

    {'noreply', State#state{call=whapps_call:set_control_queue(CtrlQ, Call)
                           ,status='proceeding'}};

handle_cast('originate_success', State) ->
    {'noreply', State#state{status='proceeding'}};


handle_cast('originate_failed', State) ->
    {'stop', 'normal', State#state{status='failed'}};


%% other end hangup
handle_cast({'hangup', HangupCause}, State) ->
    #state{call=Call} = State,
    lager:debug("presenter hanged up, cause ~p", [HangupCause]),

    %%FIXME
    Id = broadcast_util:stop_recording(Call),
    {'stop', 'normal', State#state{recordid=Id}};


handle_cast('init', State) ->
    #state{call=Call, myq=Q} = State,
    MsgId = wh_util:rand_hex_binary(16),
    lager:debug("Initializing broadcast recording presenter ~p, msgid ~p", [whapps_call:to_user(Call), MsgId]),

    AccountId = whapps_call:account_id(Call),
    [Number, _] = binary:split(whapps_call:to(Call), <<"@">>),

    case cf_util:lookup_callflow(Number, AccountId) of
        {'ok', Flow, _NoMatch} ->
            Request = broadcast_util:build_offnet_request(wh_json:get_value([<<"flow">>, <<"data">>], Flow), Call, Q),
            wapi_offnet_resource:publish_req(Request);
        {'error', Reason} ->
            lager:info("Lookup callflow for ~s in account ~s failed: ~p", [Number, AccountId, Reason]),
            gen_listener:cast(self(), 'originate_failed')
    end,
    {'noreply', State};

%% Our end stop brutally
handle_cast('stop', State) ->
    lager:debug("Stopping broadcast participant"),
    #state{call=Call} = State,
    whapps_call_command:hangup(Call),
    {'stop', {'shutdown', 'stopped'}, State#state{status='interrupted'}};

handle_cast(_Cast, State) ->
    lager:debug("unhandled cast: ~p", [_Cast]),
    {'noreply', State}.

-spec send_originate_execute(wh_json:object(), ne_binary()) -> 'ok'.
send_originate_execute(JObj, Q) ->
    CallId = wh_json:get_value([<<"Resource-Response">>, <<"Call-ID">>], JObj),
    MsgId = wh_json:get_value([<<"Resource-Response">>, <<"Msg-ID">>], JObj),
    ServerId = wh_json:get_value([<<"Resource-Response">>, <<"Server-ID">>], JObj),

    Prop = [{<<"Call-ID">>, CallId}
            ,{<<"Msg-ID">>, MsgId}
            | wh_api:default_headers(Q, ?APP_NAME, ?APP_VERSION)
           ],
    wapi_dialplan:publish_originate_execute(ServerId, Prop).

handle_event(JObj, State) ->
    #state{self=Pid} = State,
    lager:debug("received call event, ~p", [JObj]),
    case whapps_util:get_event_type(JObj) of
        {<<"resource">>, <<"offnet_resp">>} ->
            case wh_json:get_value(<<"Response-Message">>, JObj) of
                <<"READY">> ->
                    gen_listener:cast(Pid, {'originate_ready', JObj});
                _ ->
                    lager:info("Offnet request failed: ~p", [JObj]),
                    gen_listener:cast(Pid, 'originate_failed')
            end;
        {<<"resource">>, <<"originate_resp">>} ->
            case wh_json:get_value(<<"Application-Response">>, JObj) =:= <<"SUCCESS">> of
                'true' -> gen_listener:cast(Pid, 'originate_success');
                'false' -> gen_listener:cast(Pid, 'originate_failed')
            end;
        {<<"error">>, <<"originate_resp">>} ->
            lager:debug("channel execution error while waiting for originate: ~s"
                        ,[wh_util:to_binary(wh_json:encode(JObj))]),
            gen_listener:cast(Pid, 'originate_failed');
        {<<"call_event">>, <<"CHANNEL_DESTROY">>} ->
            HangupCause = wh_json:get_value(<<"Hangup-Cause">>, JObj, <<"unknown">>),
            gen_listener:cast(Pid, {'hangup', HangupCause});
        {<<"call_event">>, <<"CHANNEL_ANSWER">>} ->
            gen_listener:cast(Pid, 'answered');
        _Else ->
            lager:debug("unhandled event ~p", [JObj])
    end,
    {'reply', []}.


terminate(Reason, State) ->
    #state{recordid=Id} = State, 

    gen_listener:cast(State#state.server, {'recording_complete', Id}),
    lager:info("broadcast_participant execution has been stopped: ~p", [Reason]).

code_change(_OldVsn, State, _Extra) ->
    {'ok', State}.

init([Server, Call]) ->
    process_flag('trap_exit', 'true'),
    CallId = wh_util:rand_hex_binary(8),
    put('callid', CallId),
    {'ok', #state{call=whapps_call:set_call_id(CallId, Call)
                 ,self=self()
                 ,server=Server
                 ,status='initial'
                 ,recordid='undefined'}
    }.


