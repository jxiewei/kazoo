%%%-------------------------------------------------------------------
%%% @copyright (C) 2011-2014, 2600Hz
%%% @doc
%%% client software management module
%%%
%%% Store/retrieve clientsoft information
%%%
%%% @end
%%% @contributors
%%%   jxiewei
%%%-------------------------------------------------------------------
-module(cb_clientsoft).

-export([init/0
         ,allowed_methods/0, allowed_methods/1, allowed_methods/2
         ,resource_exists/0, resource_exists/1, resource_exists/2
         ,validate/1, validate/2, validate/3
         ,content_types_provided/3
         ,content_types_accepted/3
         ,get/3
         ,put/1
         ,post/2, post/3
         ,delete/2, delete/3
        ]).

-include("../crossbar.hrl").

-define(SERVER, ?MODULE).
-define(BIN_DATA, <<"raw">>).

-define(CB_LIST, <<"clientsoft/crossbar_listing">>).
-define(NEWESTVER, <<"clientsoft/newestver">>).

-define(MOD_CONFIG_CAT, <<(?CONFIG_CAT)/binary, ".clientsoft">>).

-define(CLIENTSOFT_MIME_TYPES, [{<<"application">>, <<"apk">>}]).


%%%===================================================================
%%% API
%%%===================================================================
init() ->
    _ = crossbar_bindings:bind(<<"*.content_types_provided.clientsoft">>, ?MODULE, 'content_types_provided'),
    _ = crossbar_bindings:bind(<<"*.content_types_accepted.clientsoft">>, ?MODULE, 'content_types_accepted'),
    _ = crossbar_bindings:bind(<<"*.allowed_methods.clientsoft">>, ?MODULE, 'allowed_methods'),
    _ = crossbar_bindings:bind(<<"*.resource_exists.clientsoft">>, ?MODULE, 'resource_exists'),
    _ = crossbar_bindings:bind(<<"*.validate.clientsoft">>, ?MODULE, 'validate'),
    _ = crossbar_bindings:bind(<<"*.execute.get.clientsoft">>, ?MODULE, 'get'),
    _ = crossbar_bindings:bind(<<"*.execute.put.clientsoft">>, ?MODULE, 'put'),
    _ = crossbar_bindings:bind(<<"*.execute.post.clientsoft">>, ?MODULE, 'post'),
    _ = crossbar_bindings:bind(<<"*.execute.delete.clientsoft">>, ?MODULE, 'delete').

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
-spec allowed_methods(path_token(), path_token()) -> http_methods().
allowed_methods() ->
    [?HTTP_GET, ?HTTP_PUT].
allowed_methods(<<"newestver">>) ->
    [?HTTP_GET];
allowed_methods(_VersionId) ->
    [?HTTP_GET, ?HTTP_DELETE].
allowed_methods(_VersionId, ?BIN_DATA) ->
    [?HTTP_GET, ?HTTP_POST].

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
-spec resource_exists(path_token(), path_token()) -> 'true'.
resource_exists() -> 'true'.
resource_exists(_) -> 'true'.
resource_exists(_, ?BIN_DATA) -> 'true'.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Add content types accepted and provided by this module
%%
%% @end
%%--------------------------------------------------------------------
-spec content_types_provided(cb_context:context(), path_token(), path_token()) ->
                                    cb_context:context().
-spec content_types_provided(cb_context:context(), path_token(), path_token(), http_method()) ->
                                    cb_context:context().
content_types_provided(Context, VersionId, ?BIN_DATA) ->
    content_types_provided(Context, VersionId, ?BIN_DATA, cb_context:req_verb(Context)).

content_types_provided(Context, VersionId, ?BIN_DATA, ?HTTP_GET) ->
    Context1 = load_clientsoft_meta(VersionId, Context),
    case cb_context:resp_status(Context1) of
        'success' ->
            JObj = cb_context:doc(Context1),
            case wh_json:get_keys(wh_json:get_value([<<"_attachments">>], JObj, [])) of
                [] -> Context;
                [Attachment|_] ->
                    CT = wh_json:get_value([<<"_attachments">>, Attachment, <<"content_type">>], JObj),
                    [Type, SubType] = binary:split(CT, <<"/">>),
                    cb_context:set_content_types_provided(Context, [{'to_binary', [{Type, SubType}]}])
            end
    end;
content_types_provided(Context, _VersionId, ?BIN_DATA, _Verb) ->
    Context.

-spec content_types_accepted(cb_context:context(), path_token(), path_token()) ->
                                    cb_context:context().
-spec content_types_accepted_for_upload(cb_context:context(), http_method()) ->
                                               cb_context:context().
content_types_accepted(Context, _VersionId, ?BIN_DATA) ->
    content_types_accepted_for_upload(Context, cb_context:req_verb(Context)).

content_types_accepted_for_upload(Context, ?HTTP_POST) ->
    CTA = [{'from_binary', ?CLIENTSOFT_MIME_TYPES}],
    cb_context:set_content_types_accepted(Context, CTA);
content_types_accepted_for_upload(Context, _Verb) ->
    Context.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function determines if the parameters and content are correct
%% for this request
%%
%% Failure here returns 400
%% @end
%%--------------------------------------------------------------------
-spec validate(cb_context:context()) -> cb_context:context().
-spec validate(cb_context:context(), path_token()) -> cb_context:context().
-spec validate(cb_context:context(), path_token(), path_token()) -> cb_context:context().

validate(Context) ->
    validate_clientsoft_docs(Context, cb_context:req_verb(Context)).

validate(Context, <<"newestver">>) ->
    QS = cb_context:query_string(Context),
    Context1 = crossbar_doc:load_view(?NEWESTVER
                           ,[{'reduce', 'true'}
                             ,{'group', 'true'}
                             ,{'key', newestver_query_key(QS)}
                            ]
                           ,Context),
    Value = wh_json:get_value(<<"value">>, lists:nth(1, cb_context:doc(Context1))),
    Routines = [fun cb_context:set_resp_data/2
               ,fun cb_context:set_doc/2],
    lists:foldl(fun(F, C) -> F(C, Value) end, Context1, Routines);
    
validate(Context, VersionId) ->
    validate_clientsoft_doc(Context, VersionId, cb_context:req_verb(Context)).

validate(Context, VersionId, ?BIN_DATA) ->
    validate_clientsoft_binary(Context, VersionId, cb_context:req_verb(Context), cb_context:req_files(Context)).

%% GET all new version summary
validate_clientsoft_docs(Context, ?HTTP_GET) ->
    load_clientsoft_summary(Context);
%%PUT new version request.
validate_clientsoft_docs(Context, ?HTTP_PUT) ->
    validate_request('undefined', Context).

%% GET version metadata
validate_clientsoft_doc(Context, VersionId, ?HTTP_GET) ->
    load_clientsoft_meta(VersionId, Context);
%% UPDATE version metadata
validate_clientsoft_doc(Context, VersionId, ?HTTP_POST) ->
    validate_request(VersionId, Context);
%% DELETE version
validate_clientsoft_doc(Context, VersionId, ?HTTP_DELETE) ->
    load_clientsoft_meta(VersionId, Context).

%% DOWNLOAD version file
validate_clientsoft_binary(Context, VersionId, ?HTTP_GET, _Files) ->
    lager:debug("fetch clientsoft contents"),
    load_clientsoft_binary(VersionId, Context);

%% UPDATE version file
validate_clientsoft_binary(Context, _VersionId, ?HTTP_POST, []) ->
    Message = <<"please provide an version file">>,
    cb_context:add_validation_error(<<"file">>, <<"required">>, Message, Context);

%% CREATE version files
validate_clientsoft_binary(Context, VersionId, ?HTTP_POST, [{_Filename, FileObj}]) ->
    Context1 = load_clientsoft_meta(VersionId, Context),
    case cb_context:resp_status(Context1) of
        'success' ->
            CT = wh_json:get_value([<<"headers">>, <<"content_type">>], FileObj, <<"application/octet-stream">>),
            Size = wh_json:get_integer_value([<<"headers">>, <<"content_length">>]
                                             ,FileObj
                                             ,byte_size(wh_json:get_value(<<"contents">>, FileObj, <<>>))
                                            ),

            Props = [{<<"content_type">>, CT}
                     ,{<<"content_length">>, Size}
                    ],
            validate_request(VersionId
                             ,cb_context:set_req_data(Context1
                                                      ,wh_json:set_values(Props, cb_context:doc(Context1))
                                                     )
                            );
        _Status -> Context1
    end;
validate_clientsoft_binary(Context, _VersionId, ?HTTP_POST, _Files) ->
    Message = <<"please provide a single version file">>,
    cb_context:add_validation_error(<<"file">>, <<"maxItems">>, Message, Context).

-spec get(cb_context:context(), path_token(), path_token()) -> cb_context:context().
get(Context, _VersionId, ?BIN_DATA) ->
    cb_context:add_resp_headers(Context
                                ,[{<<"Content-Type">>
                                   ,wh_json:get_value(<<"content-type">>, cb_context:doc(Context), <<"application/octet-stream">>)
                                  }
                                  ,{<<"Content-Length">>
                                    ,binary:referenced_byte_size(cb_context:resp_data(Context))
                                   }
                                 ]).

-spec put(cb_context:context()) -> cb_context:context().
put(Context) ->
    case cb_context:resp_status(Context) of
        'success' -> crossbar_doc:save(Context);
        _ -> Context
    end.

-spec post(cb_context:context(), path_token()) -> cb_context:context().
-spec post(cb_context:context(), path_token(), path_token()) -> cb_context:context().

post(Context, _VersionId) ->
    case cb_context:resp_status(Context) of
        'success' -> crossbar_doc:save(Context);
        _ -> Context
    end.

post(Context, VersionId, ?BIN_DATA) ->
    update_clientsoft_binary(VersionId, Context).

-spec delete(cb_context:context(), path_token()) -> cb_context:context().
-spec delete(cb_context:context(), path_token(), path_token()) -> cb_context:context().

delete(Context, _VersionId) ->
    crossbar_doc:delete(Context).
delete(Context, VersionId, ?BIN_DATA) ->
    delete_clientsoft_binary(VersionId, Context).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Attempt to load a summarized list of verison files
%% @end
%%--------------------------------------------------------------------
-spec load_clientsoft_summary(cb_context:context()) -> cb_context:context().
load_clientsoft_summary(Context) ->
    crossbar_doc:load_view(?CB_LIST, [], Context, fun normalize_view_results/2).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Load a clientsoft version document from the database
%% @end
%%--------------------------------------------------------------------
-spec load_clientsoft_meta(ne_binary(), cb_context:context()) -> cb_context:context().
load_clientsoft_meta(VersionId, Context) ->
    crossbar_doc:load(VersionId, Context).

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec validate_request(api_binary(), cb_context:context()) -> cb_context:context().
validate_request(VersionId, Context) ->
    check_clientsoft_schema(VersionId, Context).

check_clientsoft_schema(VersionId, Context) ->
    OnSuccess = fun(C) -> on_successful_validation(VersionId, C) end,
    cb_context:validate_request_data(<<"clientsoft">>, Context, OnSuccess).

on_successful_validation('undefined', Context) ->
    Props = [{<<"pvt_type">>, <<"clientsoft">>}],
    cb_context:set_doc(Context, wh_json:set_values(Props, cb_context:doc(Context)));
on_successful_validation(VersionId, Context) ->
    crossbar_doc:load_merge(VersionId, Context).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Normalizes the resuts of a view
%% @end
%%--------------------------------------------------------------------
-spec normalize_view_results(wh_json:object(), wh_json:objects()) ->
                                    wh_json:objects().
normalize_view_results(JObj, Acc) ->
    [wh_json:get_value(<<"value">>, JObj)|Acc].

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Load the binary attachment of a clientsoft version doc
%% @end
%%--------------------------------------------------------------------
-spec load_clientsoft_binary(path_token(), cb_context:context()) -> cb_context:context().
load_clientsoft_binary(VersionId, Context) ->
    Context1 = load_clientsoft_meta(VersionId, Context),
    case cb_context:resp_status(Context1) of
        'success' ->
            Metadata = wh_json:get_value([<<"_attachments">>], cb_context:doc(Context1), []),

            case wh_json:get_keys(Metadata) of
                [] -> crossbar_util:response_bad_identifier(VersionId, Context);
                [Attachment|_] ->
                    cb_context:add_resp_headers(
                      crossbar_doc:load_attachment(cb_context:doc(Context1), Attachment, Context1)
                      ,[{<<"Content-Disposition">>, <<"attachment; filename=", Attachment/binary>>}
                        ,{<<"Content-Type">>, wh_json:get_value([Attachment, <<"content_type">>], Metadata)}
                        ,{<<"Content-Length">>, wh_json:get_value([Attachment, <<"length">>], Metadata)}
                       ])
            end;
        _Status -> Context1
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Update the binary attachment of a clientsoft version doc
%% @end
%%--------------------------------------------------------------------
-spec update_clientsoft_binary(path_token(), cb_context:context()) ->
                                 cb_context:context().
update_clientsoft_binary(VersionId, Context) ->
    [{Filename, FileObj}] = cb_context:req_files(Context),

    Contents = wh_json:get_value(<<"contents">>, FileObj),
    CT = wh_json:get_value([<<"headers">>, <<"content_type">>], FileObj),
    lager:debug("file content type: ~s", [CT]),
    Opts = [{'headers', [{'content_type', wh_util:to_list(CT)}]}],

    TmpFile = wh_util:to_list(filename:join(["/tmp/", <<VersionId/binary, ".apk">>])),
    lager:debug("jerry -- tmp file ~p", [TmpFile]),
    'ok' = file:write_file(TmpFile, Contents),
    Tree = apk_parser:build(TmpFile),
    file:delete(TmpFile),
    PackageName = wh_util:to_binary(apk_parser:get_package_name(Tree)),
    VersionName = wh_util:to_binary(apk_parser:get_version_name(Tree)),
    VersionCode = wh_util:to_binary(apk_parser:get_version_code(Tree)),
    OEMName = wh_util:to_binary(apk_parser:get_oem_name(Tree)),

    JObj = cb_context:doc(Context),
    case {wh_json:get_value(<<"package_name">>, JObj), wh_json:get_value(<<"version_name">>, JObj)} of
        {PackageName, VersionName} ->
            JObj1 = wh_json:set_values(
                            props:filter_undefined( 
                                [{<<"version_code">>, VersionCode}
                                ,{<<"oem_name">>, OEMName}
                                ]), JObj),
            Context1 = cb_context:set_doc(Context, JObj1),
            crossbar_doc:save(Context1),
            Context2 = crossbar_util:maybe_remove_attachments(Context1),
            crossbar_doc:save_attachment(VersionId, cb_modules_util:attachment_name(Filename, CT)
                                 ,Contents, Context2, Opts
                                );
        _ ->
            lager:info("package name or version name mistach in apk file and couchdb"),
            crossbar_util:response('error', <<"package name or version name in file mismatch with values in db">>, Context)
    end.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Delete the binary attachment of a clientsoft version doc
%% @end
%%--------------------------------------------------------------------
-spec delete_clientsoft_binary(path_token(), cb_context:context()) -> cb_context:context().
delete_clientsoft_binary(VersionId, Context) ->
    Context1 = crossbar_doc:load(VersionId, Context),
    case cb_context:resp_status(Context1) of
        'success' ->
            case wh_json:get_value([<<"_attachments">>, 1], cb_context:doc(Context1)) of
                'undefined' -> crossbar_util:response_bad_identifier(VersionId, Context);
                AttachMeta ->
                    [AttachmentID] = wh_json:get_keys(AttachMeta),
                    crossbar_doc:delete_attachment(VersionId, AttachmentID, Context)
            end;
        _Status -> Context1
    end.


newestver_query_key(QS) ->
    wh_json:from_list(
         [{<<"package_name">>, wh_json:get_value(<<"package_name">>, QS)}
         ,{<<"oem_name">>, wh_json:get_value(<<"oem_name">>, QS)}
         ]).
