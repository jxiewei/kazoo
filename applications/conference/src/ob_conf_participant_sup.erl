%%%-------------------------------------------------------------------
%%% @copyright (C) 2012-2013, 2600Hz Inc
%%% @doc
%%% Supervisor for running conference participant processes
%%% @end
%%% @contributors
%%%   Karl Anderson
%%%-------------------------------------------------------------------
-module(ob_conf_participant_sup).

-behaviour(supervisor).

-include("conference.hrl").

%% API
-export([start_link/0]).
-export([start_ob_conf_participant/4]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%%%===================================================================
%%% API functions
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the supervisor
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
-spec start_link() -> startlink_ret().
start_link() -> supervisor:start_link({'local', ?SERVER}, ?MODULE, []).

start_ob_conf_participant(Server, Conference, OID, Call) -> 
    case supervisor:start_child(?MODULE, [Server, Conference, OID, Call]) of
    {'ok', Pid} -> {'ok', Pid};
    _R -> 
        'error'
    end.

%%%===================================================================
%%% Supervisor callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Whenever a supervisor is started using supervisor:start_link/[2,3],
%% this function is called by the new process to find out about
%% restart strategy, maximum restart frequency and child
%% specifications.
%%
%% @spec init(Args) -> {ok, {SupFlags, [ChildSpec]}} |
%%                     ignore |
%%                     {error, Reason}
%% @end
%%--------------------------------------------------------------------
-spec init([]) -> sup_init_ret().
init([]) ->
    RestartStrategy = 'simple_one_for_one',
    MaxRestarts = 0,
    MaxSecondsBetweenRestarts = 1,

    SupFlags = {RestartStrategy, MaxRestarts, MaxSecondsBetweenRestarts},

    {'ok', {SupFlags, [?WORKER_TYPE('ob_conf_participant', 'temporary')]}}.
