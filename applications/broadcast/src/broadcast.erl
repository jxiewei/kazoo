%%%-------------------------------------------------------------------
%%% @copyright (C) 2011-2012 VoIP, INC
%%% @doc
%%% Its a party and your invite'd...
%%% @end
%%% @contributors
%%%   Karl Anderson
%%%-------------------------------------------------------------------
-module(broadcast).

-include_lib("whistle/include/wh_types.hrl").

-export([start_link/0
         ,start/0
         ,stop/0
        ]).

%%--------------------------------------------------------------------
%% @public
%% @doc
%% Starts the app for inclusion in a supervisor tree
%% @end
%%--------------------------------------------------------------------
-spec start_link() -> startlink_ret().
start_link() ->
    _ = start_deps(),
    _ = declare_exchanges(),
    {ok, _} = ecron:add_event_handler(broadcast_ecron_event_handler, []),
    broadcast_sup:start_link().

%%--------------------------------------------------------------------
%% @public
%% @doc
%% Starts the application
%% @end
%%--------------------------------------------------------------------
-spec start() -> 'ok' | {'error', _}.
start() ->
    application:start(?MODULE).

%%--------------------------------------------------------------------
%% @public
%% @doc
%% Stop the app
%% @end
%%--------------------------------------------------------------------
-spec stop() -> 'ok'.
stop() ->
    exit(whereis('broadcast_sup'), 'shutdown'),
    'ok'.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Ensures that all dependencies for this app are already running
%% @end
%%--------------------------------------------------------------------

-spec start_deps() -> 'ok'.
start_deps() ->
    whistle_apps_deps:ensure(?MODULE), % if started by the whistle_controller, this will exist
    'ok' = wh_util:ensure_mnesia_ondisc(),
    _ = [wh_util:ensure_started(App) || App <- ['crypto'
                                                ,'lager'
                                                ,'whistle_amqp'
                                                ,'whistle_couch'
                                                ,'mnesia'
                                               ]],
    'ok' = ecron:install(),
    _ = wh_util:ensure_started('ecron'),
    'ok'.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Ensures that all exchanges used are declared
%% @end
%%--------------------------------------------------------------------
-spec declare_exchanges() -> 'ok'.
declare_exchanges() ->
    _ = wapi_call:declare_exchanges(),
    _ = wapi_dialplan:declare_exchanges(),
    _ = wapi_notifications:declare_exchanges(), 
    wapi_self:declare_exchanges().
