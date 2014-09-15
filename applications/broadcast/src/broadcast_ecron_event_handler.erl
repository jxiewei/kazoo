-module(broadcast_ecron_event_handler).

-behaviour(gen_event).

-export([init/1, 
         handle_event/2,
         handle_call/2,
         handle_info/2,
         code_change/3,
         terminate/2]).

-include("broadcast.hrl").

init(_Args) ->
    {ok, []}.


handle_event(Event, State) ->
    lager:debug("Received eron event: ~p", [Event]),
    {ok, State}.

%%------------------------------------------------------------------------------
%% @spec handle_call(Request, State) -> {ok, Reply, State} |
%%                                      {swap_handler, Reply, Args1, State1,
%%                                       Mod2, Args2} |
%%                                      {remove_handler, Reply}
%% @doc Whenever an event manager receives a request sent using
%% gen_event:call/3,4, this function is called for the specified event
%% handler to handle the request.
%% @end
%%------------------------------------------------------------------------------
handle_call(_Request, State) ->
  lager:debug("Received ecron call ~p", [_Request]),
  Reply = ok,
  {ok, Reply, State}.

%%------------------------------------------------------------------------------
%% @spec handle_info(Info, State) -> {ok, State} |
%%                                   {swap_handler, Args1, State1, Mod2, Args2} |
%%                                    remove_handler
%% @doc This function is called for each installed event handler when
%% an event manager receives any other message than an event or a synchronous
%% request (or a system message).
%% @end
%%------------------------------------------------------------------------------
handle_info(_Info, State) ->
    lager:debug("Received ecron info ~p", [_Info]),
  {ok, State}.

%%------------------------------------------------------------------------------
%% @spec terminate(Reason, State) -> void()
%% @doc Whenever an event handler is deleted from an event manager,
%% this function is called. It should be the opposite of Module:init/1 and
%% do any necessary cleaning up.
%% @end
%%------------------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%------------------------------------------------------------------------------
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @doc Convert process state when code is changed
%% @end
%%------------------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
  {ok, State}.
