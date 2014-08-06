-ifndef(BROADCAST_HRL).
-include_lib("whistle/include/wh_types.hrl").
-include_lib("whistle/include/wh_amqp.hrl").
-include_lib("whistle/include/wh_log.hrl").

-define(APP_NAME, <<"broadcast">>).
-define(APP_VERSION, <<"1.0.0">>).

-record(partylog, {
        tasklogid
        ,call_id
        ,caller_id_number
        ,callee_id_number
        ,start_tstamp
        ,end_tstamp
        ,answer_tstamp
        ,hangup_tstamp
        ,final_state
        ,hangup_cause
        ,owner_id
        }).


-define(BROADCAST_HRL, 'true').
-endif.
