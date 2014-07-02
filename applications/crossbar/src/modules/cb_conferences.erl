%%%-------------------------------------------------------------------
%%% @copyright (C) 2011-2012, VoIP INC
%%% @doc
%%% Conferences module
%%%
%%% Handle client requests for conference documents
%%%
%%% @end
%%% @contributors
%%%   Karl Anderson
%%%   James Aimonetti
%%%-------------------------------------------------------------------
-module(cb_conferences).

-export([init/0
         ,allowed_methods/0, allowed_methods/1
         ,allowed_methods/2
         ,resource_exists/0, resource_exists/1
         ,resource_exists/2, resource_exists/3
         ,validate/1, validate/2
         ,validate/3, validate/4
         ,put/1
         ,post/2, post/3, post/4
         ,delete/2
        ]).

-include("../crossbar.hrl").

-define(KICKOFF_PATH_TOKEN, <<"kickoff">>).
-define(KICKOFF_URL, [{<<"conferences">>, [_, ?KICKOFF_PATH_TOKEN]}
                      ,{?WH_ACCOUNT_DB, [_]}
                     ]).
-define(PICKUP_PATH_TOKEN, <<"pickup">>).
-define(PICKUP_URL, [{<<"conferences">>, [_, ?PICKUP_PATH_TOKEN, _]}
                     ,{?WH_ACCOUNT_DB, [_]}
                    ]).
-define(KICKOUT_PATH_TOKEN, <<"kickout">>).
-define(KICKOUT_URL, [{<<"conferences">>, [_, ?KICKOUT_PATH_TOKEN, _]}
                     ,{?WH_ACCOUNT_DB, [_]}
                    ]).
-define(SUCCESSFUL_HANGUP_CAUSES, [<<"NORMAL_CLEARING">>, <<"ORIGINATOR_CANCEL">>, <<"SUCCESS">>]).

-define(CB_LIST, <<"conferences/crossbar_listing">>).
-define(DEVICES_VIEW, <<"devices/listing_by_owner">>).


%%%===================================================================
%%% API
%%%===================================================================
init() ->
    _ = crossbar_bindings:bind(<<"*.allowed_methods.conferences">>, ?MODULE, allowed_methods),
    _ = crossbar_bindings:bind(<<"*.resource_exists.conferences">>, ?MODULE, resource_exists),
    _ = crossbar_bindings:bind(<<"*.validate.conferences">>, ?MODULE, validate),
    _ = crossbar_bindings:bind(<<"*.execute.put.conferences">>, ?MODULE, put),
    _ = crossbar_bindings:bind(<<"*.execute.post.conferences">>, ?MODULE, post),
    crossbar_bindings:bind(<<"*.execute.delete.conferences">>, ?MODULE, delete).

%%--------------------------------------------------------------------
%% @public
%% @doc
%% This function determines the verbs that are appropriate for the
%% given Nouns.  IE: '/accounts/' can only accept GET and PUT
%%
%% Failure here returns 405
%% @end
%%--------------------------------------------------------------------
-spec allowed_methods() -> http_methods().
-spec allowed_methods(path_token()) -> http_methods().
allowed_methods() ->
    [?HTTP_GET, ?HTTP_PUT].
allowed_methods(_) ->
    [?HTTP_GET, ?HTTP_POST, ?HTTP_DELETE].
allowed_methods(_, ?KICKOFF_PATH_TOKEN) ->
    [?HTTP_POST];
allowed_methods(_, ?PICKUP_PATH_TOKEN) ->
    [?HTTP_POST];
allowed_methods(_, ?KICKOUT_PATH_TOKEN) ->
    [?HTTP_POST].

%%--------------------------------------------------------------------
%% @public
%% @doc
%% This function determines if the provided list of Nouns are valid.
%%
%% Failure here returns 404
%% @end
%%--------------------------------------------------------------------
-spec resource_exists() -> 'true'.
-spec resource_exists(path_token()) -> 'true'.
resource_exists() ->
    true.
resource_exists(_) ->
    true.
resource_exists(_, ?KICKOFF_PATH_TOKEN) ->
    true.
resource_exists(_, ?PICKUP_PATH_TOKEN, _) ->
    true;
resource_exists(_, ?KICKOUT_PATH_TOKEN, _) ->
    true.


%%--------------------------------------------------------------------
%% @public
%% @doc
%% This function determines if the parameters and content are correct
%% for this request
%%
%% Failure here returns 400
%% @end
%%--------------------------------------------------------------------
-spec validate(#cb_context{}) -> #cb_context{}.
-spec validate(#cb_context{}, path_token()) -> #cb_context{}.
validate(#cb_context{req_verb = ?HTTP_GET}=Context) ->
    load_conference_summary(Context);
validate(#cb_context{req_verb = ?HTTP_PUT}=Context) ->
    create_conference(Context).

validate(#cb_context{req_verb = ?HTTP_GET}=Context, Id) ->
    load_conference(Id, Context);
validate(#cb_context{req_verb = ?HTTP_POST}=Context, Id) ->
    update_conference(Id, Context);
validate(#cb_context{req_verb = ?HTTP_DELETE}=Context, Id) ->
    load_conference(Id, Context).

validate(Context, ConferenceId, ?KICKOFF_PATH_TOKEN) ->
    %TODO: call conference members/moderators and bridge them to the conference.
    Context1 = load_conference(ConferenceId, Context),
    case cb_context:resp_status(Context1) of
        'success' -> kickoff_conference(Context1);
        _Status -> Context1
    end.

validate(Context, ConferenceId, ?PICKUP_PATH_TOKEN, _Number) ->
    %TODO: call CalleeNum and bridge it to the conference.
    Context1 = load_conference(ConferenceId, Context),
    case cb_context:resp_status(Context1) of
        %'success' -> pickup_conf_participant(ConferenceId, _Number, Context1);
        _Status -> Context1
    end;

validate(Context, ConferenceId, ?KICKOFF_PATH_TOKEN, _Number) ->
    %TODO: kick CalleeNum out of the conference.
    Context1 = load_conference(ConferenceId, Context),
    case cb_context:resp_status(Context1) of
        %'success' -> kickout_conf_participatn(ConferenceId, _Number, Context1);
        _Status -> Context1
    end.


-spec post(#cb_context{}, path_token()) -> #cb_context{}.
post(Context, _) ->
    crossbar_doc:save(Context).

post(Context, _, ?KICKOFF_PATH_TOKEN) ->
    Context.

post(Context, _, ?PICKUP_PATH_TOKEN, _) ->
    Context;
post(Context, _, ?KICKOUT_PATH_TOKEN, _) ->
    Context.

-spec put(#cb_context{}) -> #cb_context{}.
put(Context) ->
    crossbar_doc:save(Context).

-spec delete(#cb_context{}, path_token()) -> #cb_context{}.
delete(Context, _) ->
    crossbar_doc:delete(Context).

%%%===================================================================
%%% Internal functions
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Attempt to load list of accounts, each summarized.  Or a specific
%% account summary.
%% @end
%%--------------------------------------------------------------------
-spec load_conference_summary(#cb_context{}) -> #cb_context{}.
load_conference_summary(#cb_context{req_nouns=Nouns}=Context) ->
    case lists:nth(2, Nouns) of
        {<<"users">>, [UserId]} ->
            Filter = fun(J, A) ->
                             normalize_users_results(J, A, UserId)
                     end,
            crossbar_doc:load_view(?CB_LIST, [], Context, Filter);
        {?WH_ACCOUNTS_DB, _} ->
            crossbar_doc:load_view(?CB_LIST, [], Context, fun normalize_view_results/2);
        _ ->
            cb_context:add_system_error(faulty_request, Context)
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Create a new conference document with the data provided, if it is valid
%% @end
%%--------------------------------------------------------------------
-spec create_conference(#cb_context{}) -> #cb_context{}.
create_conference(#cb_context{}=Context) ->
    OnSuccess = fun(C) -> on_successful_validation(undefined, C) end,
    cb_context:validate_request_data(<<"conferences">>, Context, OnSuccess).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Load a conference document from the database
%% @end
%%--------------------------------------------------------------------
-spec load_conference(ne_binary(), #cb_context{}) -> #cb_context{}.
load_conference(DocId, Context) ->
    crossbar_doc:load(DocId, Context).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Update an existing conference document with the data provided, if it is
%% valid
%% @end
%%--------------------------------------------------------------------
-spec update_conference(ne_binary(), #cb_context{}) -> #cb_context{}.
update_conference(DocId, #cb_context{}=Context) ->
    OnSuccess = fun(C) -> on_successful_validation(DocId, C) end,
    cb_context:validate_request_data(<<"conferences">>, Context, OnSuccess).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% 
%% @end
%%--------------------------------------------------------------------
-spec on_successful_validation('undefined' | ne_binary(), #cb_context{}) -> #cb_context{}.
on_successful_validation(undefined, #cb_context{doc=JObj}=Context) ->
    Context#cb_context{doc=wh_json:set_value(<<"pvt_type">>, <<"conference">>, JObj)};
on_successful_validation(DocId, #cb_context{}=Context) ->
    crossbar_doc:load_merge(DocId, Context).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Normalizes the resuts of a view
%% @end
%%--------------------------------------------------------------------
-spec normalize_view_results(wh_json:object(), wh_json:objects()) -> wh_json:objects().
normalize_view_results(JObj, Acc) ->
    [wh_json:get_value(<<"value">>, JObj)|Acc].

-spec normalize_users_results(wh_json:object(), wh_json:objects(), ne_binary()) ->
                                          ['undefined' | wh_json:object(),...] | [].
normalize_users_results(JObj, Acc, UserId) ->
    case wh_json:get_value([<<"value">>, <<"owner_id">>], JObj) of
        undefined -> normalize_view_results(JObj, Acc);
        UserId -> normalize_view_results(JObj, Acc);
        _ -> [undefined|Acc]
    end.

kickoff_conference(Context) ->
    JObj = cb_context:doc(Context),
    AccountId = cb_context:account_id(Context),
    AccountDb = cb_context:account_db(Context),

    {'ok', AuthDoc} = couch_mgr:open_cache_doc(?TOKEN_DB, cb_context:auth_token(Context)),
    UserId = wh_json:get_value(<<"owner_id">>, AuthDoc),

    lager:debug("jerry -- starting ob conference process(~p, ~p, ~p)~n", [AccountId, UserId, wh_json:get_value(<<"_id">>, JObj)]),
    lager:debug("jerry -- ~p~n", [ob_conference_sup:start_ob_conference(AccountId, UserId, wh_json:get_value(<<"_id">>, JObj))]),
    crossbar_util:response_202(<<"processing request">>, Context).
