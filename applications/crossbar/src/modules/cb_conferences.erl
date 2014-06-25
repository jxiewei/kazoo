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


gen_conf_data(Conference) ->
    {Mute, Deaf} =
        case whapps_conference:moderator(Conference) of
            'true' ->
                {whapps_conference:moderator_join_muted(Conference)
                 ,whapps_conference:moderator_join_deaf(Conference)
                };
            'false' ->
                {whapps_conference:member_join_muted(Conference)
                 ,whapps_conference:member_join_deaf(Conference)
                }
        end,
    Command = [{<<"Conference-ID">>, whapps_conference:id(Conference)}
               ,{<<"Mute">>, Mute}
               ,{<<"Deaf">>, Deaf}
               ,{<<"Moderator">>, whapps_conference:moderator(Conference)}
               ,{<<"Profile">>, whapps_conference:profile(Conference)}
              ].

process_participant(_Type, Number, Context) ->
    JObj = cb_context:doc(Context),
    AccountId = cb_context:account_id(Context),
    AccountDb = cb_context:account_db(Context),

    {'ok', AuthDoc} = couch_mgr:open_cache_doc(?TOKEN_DB, cb_context:auth_token(Context)),
    UserId = wh_json:get_value(<<"owner_id">>, AuthDoc),
    {'ok', UserDoc} = couch_mgr:open_cache_doc(AccountDb, UserId),
    {'ok', ConferenceDoc} = couch_mgr:open_cache_doc(AccountDb, wh_json:get_value(<<"_id">>, JObj)),
    lager:debug("==jerry== conerence_id ~p, conference doc ~p~n", [wh_json:get_value(<<"_id">>, JObj), ConferenceDoc]),

    ViewOptions = [{'key', UserId}],
    case couch_mgr:get_results(AccountDb, ?DEVICES_VIEW, ViewOptions) of
        {'ok', JObjs} ->
            SipDevices = lists:filter(fun(Obj) -> 
                                        {'ok', Dev} = couch_mgr:open_cache_doc(AccountDb, wh_json:get_value([<<"value">>, <<"id">>], Obj)),
                                        wh_json:get_value(<<"device_type">>, Dev) =:= <<"softphone">>
                                      end, JObjs),
            DeviceId = wh_json:get_value(<<"id">>, lists:nth(1, SipDevices));
        {'error', _R} ->
            DeviceId = 'undefined',
            lager:debug("softphone device owned by ~p not found~n", [UserId])
    end,


    {'ok', AccountDoc} = couch_mgr:open_cache_doc(?WH_ACCOUNTS_DB, AccountId),
    {'ok', RequestDevice} = couch_mgr:open_cache_doc(AccountDb, DeviceId),
    CallerId = wh_json:get_value([<<"caller_id">>, <<"external">>], UserDoc),
    Realm = wh_json:get_ne_value(<<"realm">>, AccountDoc),
    FromUser = wh_json:get_value([<<"sip">>, <<"username">>], RequestDevice),
    MsgId = wh_json:get_value(<<"Msg-ID">>, JObj, wh_util:rand_hex_binary(16)),

    CCVs = [{<<"Account-ID">>, AccountId}
            ,{<<"Retain-CID">>, <<"true">>}
            ,{<<"Inherit-Codec">>, <<"false">>}
            ,{<<"Authorizing-Type">>, <<"device">>}
            ,{<<"Authorizing-ID">>, DeviceId} 
           ],

    Endpoint = [{<<"Invite-Format">>, <<"route">>}
                ,{<<"Route">>,  <<"loopback/", Number/binary, "/context_2">>}
                ,{<<"To-DID">>, Number}
                ,{<<"To-Realm">>, Realm}
                ,{<<"Custom-Channel-Vars">>, wh_json:from_list(CCVs)}
               ],


    C = whapps_conference:from_conference_doc(ConferenceDoc),
    Conference = 
        case _Type of
            moderator -> whapps_conference:set_moderator('true', C);
            member -> whapps_conference:set_moderator('false', C)
        end,
    whapps_conference:set_application_version(<<"2.0.0">>, Conference),
    whapps_conference:set_application_name(<<"conferences">>, Conference), 
    lager:debug("==jerry== whapps_conference ~p~n", [Conference]),
    AppData = gen_conf_data(Conference),
    lager:debug("==jerry== conference data ~p~n", [AppData]),
    Request = props:filter_undefined(
                [{<<"Application-Name">>, <<"conference">>}
                 ,{<<"Application-Data">>, wh_json:from_list(AppData)}
                 ,{<<"Msg-ID">>, MsgId}
                 ,{<<"Endpoints">>, [wh_json:from_list(Endpoint)]}
                 ,{<<"Outbound-Caller-ID-Name">>, wh_json:get_value(<<"name">>, CallerId)}
                 ,{<<"Outbound-Caller-ID-Number">>, wh_json:get_value(<<"number">>, CallerId)}
                 ,{<<"Outbound-Callee-ID-Name">>, Number}
                 ,{<<"Outbound-Callee-ID-Number">>, Number}
                 ,{<<"Request">>,<<FromUser/binary, <<"@">>/binary, Realm/binary>>} 
                 ,{<<"From">>, <<FromUser/binary, <<"@">>/binary, Realm/binary>>}
                 ,{<<"Dial-Endpoint-Method">>, <<"single">>}
                 ,{<<"Continue-On-Fail">>, 'true'}
                 ,{<<"Custom-Channel-Vars">>, wh_json:from_list(CCVs)}
                 ,{<<"Export-Custom-Channel-Vars">>, [<<"Account-ID">>, <<"Retain-CID">>, <<"Authorizing-ID">>, <<"Authorizing-Type">>]}
                 | wh_api:default_headers(<<"resource">>, <<"originate_req">>, ?APP_NAME, ?APP_VERSION)
                ]),

    case whapps_util:amqp_pool_collect(Request
                                       ,fun wapi_resource:publish_originate_req/1
                                       ,fun is_resp/1
                                       ,20000
                                      )
    of
        {'ok', [Resp|_]} ->
            AppResponse = wh_json:get_first_defined([<<"Application-Response">>
                                                     ,<<"Hangup-Cause">>
                                                     ,<<"Error-Message">>
                                                    ], Resp),
            lager:debug("==jerry== app respond ok ~p~n", [Resp]),
            case lists:member(AppResponse, ?SUCCESSFUL_HANGUP_CAUSES) of
                'true' ->
                    {'success', wh_json:get_value(<<"Call-ID">>, Resp)};
                'false' when AppResponse =:= 'undefined' ->
                    {'success', wh_json:get_value(<<"Call-ID">>, Resp)};
                'false' ->
                    lager:debug("app response ~s not successful: ~p", [AppResponse, Resp]),
                    {'error', AppResponse}
            end;
        {'returned', _JObj, Return} ->
            lager:debug("==jerry== amqp_pool_collect returned: ~p~n", [Return]),
            case {wh_json:get_value(<<"code">>, Return)
                  ,wh_json:get_value(<<"message">>, Return)
                 }
            of
                {312, _Msg} ->
                    lager:debug("no resources available to take request: ~s", [_Msg]),
                    {'error', <<"no resources">>};
                {_Code, Msg} ->
                    lager:debug("failed to publish request: ~p: ~s", [_Code, Msg]),
                    {'error', <<"request failed: ", Msg>>}
            end;
        {'error', _E} ->
            lager:debug("errored while originating: ~p", [_E]),
            {'error', <<"timed out">>};
        {'timeout', _T} ->
            lager:debug("timed out while originating: ~p", [_T]),
            {'error', <<"timed out">>}
    end.

-spec is_resp(wh_json:objects() | wh_json:object()) -> boolean().
is_resp([JObj|_]) -> is_resp(JObj);
is_resp(JObj) ->
    wapi_resource:originate_resp_v(JObj) orelse
        wh_api:error_resp_v(JObj).

kickoff_conference(Context) ->
    %originate callee simutaneously
    JObj = cb_context:doc(Context),
    Moderators = wh_json:get_value([<<"moderator">>, <<"numbers">>], JObj),
    Members = wh_json:get_value([<<"member">>, <<"numbers">>], JObj),
    ReqId = cb_context:req_id(Context),
    put('callid', ReqId),

    lists:foreach(fun(Number) -> process_participant(moderator, Number, Context) end, Moderators),
    lists:foreach(fun(Number) -> process_participant(member, Number, Context) end, Members),
    crossbar_util:response_202(<<"processing request">>, Context).
