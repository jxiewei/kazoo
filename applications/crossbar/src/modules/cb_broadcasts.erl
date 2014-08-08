%%%-------------------------------------------------------------------
%%% @copyright (C) 2011-2012, VoIP INC
%%% @doc
%%% Broadcast module
%%%
%%% Handle client requests for broadcast tasks 
%%%
%%% @end
%%% @contributors
%%%   Karl Anderson
%%%   James Aimonetti
%%%-------------------------------------------------------------------
-module(cb_broadcasts).

-export([init/0
         ,allowed_methods/0, allowed_methods/1
         ,allowed_methods/2
         ,resource_exists/0, resource_exists/1
         ,resource_exists/2
         ,validate/1, validate/2
         ,validate/3
         ,put/1, post/2
         ,delete/2
        ]).

-include("../crossbar.hrl").

-define(CB_LIST, <<"broadcasts/crossbar_listing">>).
-define(STATUS_PATH_TOKEN, <<"status">>).


%%%===================================================================
%%% API
%%%===================================================================
init() ->
    _ = crossbar_bindings:bind(<<"*.allowed_methods.broadcasts">>, ?MODULE, allowed_methods),
    _ = crossbar_bindings:bind(<<"*.resource_exists.broadcasts">>, ?MODULE, resource_exists),
    _ = crossbar_bindings:bind(<<"*.validate.broadcasts">>, ?MODULE, validate),
    _ = crossbar_bindings:bind(<<"*.execute.put.broadcasts">>, ?MODULE, put),
    _ = crossbar_bindings:bind(<<"*.execute.post.broadcasts">>, ?MODULE, post),
    crossbar_bindings:bind(<<"*.execute.delete.broadcasts">>, ?MODULE, delete).

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
allowed_methods(_, ?STATUS_PATH_TOKEN) ->
    [?HTTP_GET].

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
resource_exists(_, ?STATUS_PATH_TOKEN) ->
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
    load_broadcast_summary(Context);
validate(#cb_context{req_verb = ?HTTP_PUT}=Context) ->
    create_broadcast(Context).

validate(#cb_context{req_verb = ?HTTP_GET}=Context, Id) ->
    load_broadcast(Id, Context);
validate(#cb_context{req_verb = ?HTTP_POST}=Context, Id) ->
    update_broadcast(Id, Context);
validate(#cb_context{req_verb = ?HTTP_DELETE}=Context, Id) ->
    load_broadcast(Id, Context).

validate(#cb_context{req_verb = ?HTTP_GET}=Context, Id, ?STATUS_PATH_TOKEN) ->
    Context1 = load_broadcast(Id, Context),
    case broadcast_task:status(Id) of
        {'ok', Status} -> 
            crossbar_util:response(wh_json:from_list(Status), Context1);
        _ ->
            crossbar_util:response('error', <<"broadcast not started">>, 500, Context1)
    end.

-spec post(#cb_context{}, path_token()) -> #cb_context{}.
post(Context, _) ->
    crossbar_doc:save(Context).

-spec put(#cb_context{}) -> #cb_context{}.
put(Context) ->
    Context1 = crossbar_doc:save(Context),
    AccountId = cb_context:account_id(Context),
    {'ok', AuthDoc} = couch_mgr:open_cache_doc(?TOKEN_DB, cb_context:auth_token(Context)),
    UserId = wh_json:get_value(<<"owner_id">>, AuthDoc),
    DocId = wh_json:get_value(<<"_id">>, cb_context:doc(Context1)),

    case broadcast_task:start(AccountId, UserId, DocId) of
        'ok' -> Context1;
        {'error', Reason} ->
            couch_mgr:del_doc(cb_context:account_db(Context1), cb_context:doc(Context1)),
            crossbar_util:response('error', <<"Broadcast task failed to start, reason: ", Reason/binary>>, 500, Context1)
    end.

-spec delete(#cb_context{}, path_token()) -> #cb_context{}.
delete(Context, _) ->
    DocId = wh_json:get_value(<<"_id">>, cb_context:doc(Context)),
    _ = broadcast_task:stop(DocId),
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
-spec load_broadcast_summary(#cb_context{}) -> #cb_context{}.
load_broadcast_summary(#cb_context{req_nouns=Nouns}=Context) ->
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
-spec create_broadcast(#cb_context{}) -> #cb_context{}.
create_broadcast(#cb_context{}=Context) ->
    OnSuccess = fun(C) -> on_successful_validation(undefined, C) end,
    cb_context:validate_request_data(<<"broadcasts">>, Context, OnSuccess).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Load a conference document from the database
%% @end
%%--------------------------------------------------------------------
-spec load_broadcast(ne_binary(), #cb_context{}) -> #cb_context{}.
load_broadcast(DocId, Context) ->
    crossbar_doc:load(DocId, Context).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Update an existing conference document with the data provided, if it is
%% valid
%% @end
%%--------------------------------------------------------------------
-spec update_broadcast(ne_binary(), #cb_context{}) -> #cb_context{}.
update_broadcast(DocId, #cb_context{}=Context) ->
    OnSuccess = fun(C) -> on_successful_validation(DocId, C) end,
    cb_context:validate_request_data(<<"broadcasts">>, Context, OnSuccess).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% 
%% @end
%%--------------------------------------------------------------------
-spec on_successful_validation('undefined' | ne_binary(), #cb_context{}) -> #cb_context{}.
on_successful_validation(undefined, #cb_context{doc=JObj}=Context) ->
    Context#cb_context{doc=wh_json:set_value(<<"pvt_type">>, <<"broadcast">>, JObj)};
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


