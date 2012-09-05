%%%-------------------------------------------------------------------
%%% @copyright (C) 2012, VoIP INC
%%% @doc
%%%
%%% Data: {
%%%   "id":"queue id"
%%% }
%%%
%%% @end
%%% @contributors
%%%   James Aimonetti
%%%-------------------------------------------------------------------
-module(cf_acdc_member).

-export([handle/2]).

-include("../callflow.hrl").

%%--------------------------------------------------------------------
%% @public
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec handle/2 :: (wh_json:json_object(), whapps_call:call()) -> 'ok'.
handle(Data, Call) ->
    QueueId = wh_json:get_value(<<"id">>, Data),

    MemberCall = props:filter_undefined(
                   [{<<"Account-ID">>, whapps_call:account_id(Call)}
                    ,{<<"Queue-ID">>, QueueId}
                    ,{<<"Call">>, whapps_call:to_json(Call)}
                    | wh_api:default_headers(?APP_NAME, ?APP_VERSION)
                   ]),

    lager:debug("loading queue ~s", [QueueId]),
    {ok, QueueJObj} = couch_mgr:open_cache_doc(whapps_call:account_db(Call), QueueId),

    MaxWait = max_wait(wh_json:get_integer_value(<<"connection_timeout">>, QueueJObj, 3600)),
    MaxQueueSize = max_queue_size(wh_json:get_integer_value(<<"max_queue_size">>, QueueJObj, 0)),

    CurrQueueSize = wapi_acdc_queue:queue_size(whapps_call:account_id(Call), QueueId),

    lager:debug("max size: ~p curr size: ~p", [MaxQueueSize, CurrQueueSize]),

    maybe_enter_queue(Call, MemberCall, MaxWait, is_queue_full(MaxQueueSize, CurrQueueSize)).

maybe_enter_queue(Call, _, _, true) ->
    lager:debug("queue has reached max size"),
    cf_exe:continue(Call);
maybe_enter_queue(Call, MemberCall, MaxWait, false) ->
    lager:debug("asking for an agent, waiting up to ~p s", [MaxWait]),
    case whapps_util:amqp_pool_request(MemberCall
                                       ,fun wapi_acdc_queue:publish_member_call/1
                                       ,fun wapi_acdc_queue:member_call_success_v/1
                                       ,MaxWait
                                      ) of
        {ok, _SuccessJObj} ->
            lager:debug("agent took the member_call: ~p", [_SuccessJObj]),
            cf_exe:control_usurped(Call);
        {error, timeout} ->
            lager:debug("member_call timed out waiting in the queue for ~p s", [MaxWait]),
            cf_exe:continue(Call);
        {error, _Fail} ->
            lager:debug("failed to process the member_call: ~p", [_Fail]),
            cf_exe:continue(Call)
    end.

%% convert from seconds to milliseconds, or infinity
-spec max_wait/1 :: (integer()) -> pos_integer() | 'infinity'.
max_wait(N) when N < 1 -> infinity;
max_wait(N) -> N * 1000.

max_queue_size(N) when is_integer(N), N > 0 -> N;
max_queue_size(_) -> 0.

-spec is_queue_full/2 :: (non_neg_integer(), non_neg_integer()) -> boolean().
is_queue_full(0, _) -> false;
is_queue_full(MaxQueueSize, CurrQueueSize) -> CurrQueueSize >= MaxQueueSize.
