%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2007-2021 VMware, Inc. or its affiliates.  All rights reserved.
%%

-module(rabbit_exchange_type_consistent_hash).
-include_lib("rabbit_common/include/rabbit.hrl").
-include_lib("rabbit_common/include/rabbit_framing.hrl").

-include("rabbitmq_consistent_hash_exchange.hrl").

-behaviour(rabbit_exchange_type).

-export([description/0, serialise_events/0, route/2]).
-export([validate/1, validate_binding/2,
         create/2, delete/3, policy_changed/2,
         add_binding/3, remove_bindings/3, assert_args_equivalence/2]).
-export([init/0]).
-export([info/1, info/2]).
-export([ring_state/2]).

-export([mds_migration/3,
         mnesia_write_to_khepri/3,
         mnesia_delete_to_khepri/3,
         clear_data_in_khepri/2]).

-rabbit_boot_step(
   {rabbit_exchange_type_consistent_hash_registry,
    [{description, "exchange type x-consistent-hash: registry"},
     {mfa,         {rabbit_registry, register,
                    [exchange, <<"x-consistent-hash">>, ?MODULE]}},
     {requires,    rabbit_registry},
     {enables,     kernel_ready},
     {cleanup,     {rabbit_registry, unregister,
                    [exchange, <<"x-consistent-hash">>]}}]}).

-rabbit_boot_step(
   {rabbit_exchange_type_consistent_hash_metadata_store,
    [{description, "exchange type x-consistent-hash: shared state"},
     {mfa,         {?MODULE, init, []}},
     {requires,    database},
     {enables,     external_infrastructure}]}).

-rabbit_feature_flag(
   {rabbit_consistent_hash_exchange_raft_based_metadata_store,
    #{desc          => "Use the new Raft-based metadata store",
      doc_url       => "", %% TODO
      stability     => experimental,
      depends_on    => [raft_based_metadata_store_phase1],
      migration_fun => {?MODULE, mds_migration}
     }}).

%% This data model allows for efficient routing and exchange deletion
%% but less efficient (linear) binding management.

-define(HASH_RING_STATE_TABLE, rabbit_exchange_type_consistent_hash_ring_state).

-define(PROPERTIES, [<<"correlation_id">>, <<"message_id">>, <<"timestamp">>]).

%% OTP 19.3 does not support exs1024s
-define(SEED_ALGORITHM, exs1024).

init() ->
    rabbit_khepri:try_mnesia_or_khepri(
      fun() ->
              mnesia:create_table(?HASH_RING_STATE_TABLE, [{record_name, chx_hash_ring},
                                                           {attributes, record_info(fields, chx_hash_ring)},
                                                           {type, ordered_set}]),
              mnesia:add_table_copy(?HASH_RING_STATE_TABLE, node(), ram_copies),
              rabbit_table:wait([?HASH_RING_STATE_TABLE])
      end,
      fun() ->
              ok
      end),
    recover(),
    ok.

info(_X) -> [].
info(_X, _) -> [].

description() ->
    [{description, <<"Consistent Hashing Exchange">>}].

serialise_events() -> false.

route(#exchange {name      = Name,
                 arguments = Args},
      #delivery {message = Msg}) ->
    rabbit_khepri:try_mnesia_or_khepri(
      fun() ->
              case ets:lookup(?HASH_RING_STATE_TABLE, Name) of
                  []  ->
                      [];
                  [#chx_hash_ring{bucket_map = BM}] ->
                      case maps:size(BM) of
                          0 -> [];
                          N ->
                              K              = value_to_hash(hash_on(Args), Msg),
                              SelectedBucket = jump_consistent_hash(K, N),
                              case maps:get(SelectedBucket, BM, undefined) of
                                  undefined ->
                                      rabbit_log:warning("Bucket ~p not found", [SelectedBucket]),
                                      [];
                                  Queue     -> [Queue]
                              end
                      end
              end
      end,
      fun() ->
              Path = khepri_consistent_hash_path(Name),
              case rabbit_khepri:get(Path) of
                  {ok, #{data := #chx_hash_ring{bucket_map = BM}}} ->
                      case maps:size(BM) of
                          0 -> [];
                          N ->
                              K              = value_to_hash(hash_on(Args), Msg),
                              SelectedBucket = jump_consistent_hash(K, N),
                              case maps:get(SelectedBucket, BM, undefined) of
                                  undefined ->
                                      rabbit_log:warning("Bucket ~p not found", [SelectedBucket]),
                                      [];
                                  Queue     -> [Queue]
                              end
                      end;
                  _ ->
                      []
              end
      end).

validate(#exchange{arguments = Args}) ->
    case hash_args(Args) of
        {undefined, undefined} ->
            ok;
        {undefined, {_Type, Value}} ->
            case lists:member(Value, ?PROPERTIES) of
                true  -> ok;
                false ->
                    rabbit_misc:protocol_error(precondition_failed,
                                               "Unsupported property: ~s",
                                               [Value])
            end;
        {_, undefined} ->
            ok;
        {_, _} ->
            rabbit_misc:protocol_error(precondition_failed,
                                       "hash-header and hash-property are mutually exclusive",
                                       [])
    end.

validate_binding(_X, #binding { key = K }) ->
    try
        V = list_to_integer(binary_to_list(K)),
        case V < 1 of
            true -> {error, {binding_invalid, "The binding key must be greater than 0", []}};
            false -> ok
        end
    catch error:badarg ->
            {error, {binding_invalid, "The binding key must be an integer: ~p", [K]}}
    end.

maybe_initialise_hash_ring_state(transaction, #exchange{name = Name}) ->
    maybe_initialise_hash_ring_state(transaction, Name);
maybe_initialise_hash_ring_state(transaction, X = #resource{}) ->
    rabbit_khepri:try_mnesia_or_khepri(
      fun() ->
              maybe_initialise_hash_ring_state_in_mnesia(X)
      end,
      fun() ->
              maybe_initialise_hash_ring_state_in_khepri(X)
      end);
maybe_initialise_hash_ring_state(_, X) ->
    rabbit_khepri:try_mnesia_or_khepri(
      fun() ->
              rabbit_misc:execute_mnesia_transaction(
                fun() -> maybe_initialise_hash_ring_state_in_mnesia(X) end)
      end,
      fun() ->
              maybe_initialise_hash_ring_state_in_khepri(X)
      end).

maybe_initialise_hash_ring_state_in_mnesia(X) ->
    case mnesia:read(?HASH_RING_STATE_TABLE, X) of
        [_] -> ok;
        []  ->
            rabbit_log:debug("Consistent hashing exchange: will initialise hashing ring schema database record"),
            mnesia:write_lock_table(?HASH_RING_STATE_TABLE),
            ok = mnesia:write(?HASH_RING_STATE_TABLE, #chx_hash_ring{
                                                         exchange = X,
                                                         next_bucket_number = 0,
                                                         bucket_map = #{}}, write)
    end.

maybe_initialise_hash_ring_state_in_khepri(X) ->
    Path = khepri_consistent_hash_path(X),
    case rabbit_khepri:create(Path, #chx_hash_ring{exchange = X,
                                                   next_bucket_number = 0,
                                                   bucket_map = #{}}) of
        {ok, _} -> ok;
        {error, {mismatching_node, _}} -> ok;
        Error -> Error
    end.

recover() ->
    %% topology recovery has already happened, we have to recover state for any durable
    %% consistent hash exchanges since plugin activation was moved later in boot process
    %% starting with RabbitMQ 3.8.4
    case list_exchanges() of
        {error, Reason} ->
            rabbit_log:error(
              "Consistent hashing exchange: failed to recover durable exchange ring state, reason: ~p",
              [Reason]);
        Xs ->
            rabbit_log:debug("Consistent hashing exchange: have ~b durable exchanges to recover", [length(Xs)]),
            %% TODO we need to know if we're first on the cluster to reset storage. In mnesia it's a ram table
            [recover_exchange_and_bindings(X) || X <- lists:usort(Xs)]
    end.

list_exchanges() ->
    Pattern = #exchange{durable = true, type = 'x-consistent-hash', _ = '_'},
    rabbit_store:match_exchanges(Pattern).

recover_exchange_and_bindings(#exchange{name = XName} = X) ->
    rabbit_khepri:try_mnesia_or_khepri(
      fun() ->
              recover_exchange_and_bindings_in_mnesia(X)
      end,
      fun() ->
              %% TODO should this happen on a single transaction?
              rabbit_log:debug("Consistent hashing exchange: recovered exchange ~s", [rabbit_misc:rs(XName)]),
              create(transaction, X),
              rabbit_log:debug("Consistent hashing exchange: recovered exchange ~s", [rabbit_misc:rs(XName)]),
              Bindings = rabbit_binding:list_for_source(XName),
              rabbit_log:debug("Consistent hashing exchange: have ~b bindings to recover for exchange ~s",
                               [length(Bindings), rabbit_misc:rs(XName)]),
              [add_binding(transaction, X, B) || B <- lists:usort(Bindings)],
              rabbit_log:debug("Consistent hashing exchange: recovered bindings for exchange ~s",
                               [rabbit_misc:rs(XName)])
      end).

recover_exchange_and_bindings_in_mnesia(#exchange{name = XName} = X) ->
    mnesia:transaction(
        fun () ->
            rabbit_log:debug("Consistent hashing exchange: will recover exchange ~s", [rabbit_misc:rs(XName)]),
            create(transaction, X),
            rabbit_log:debug("Consistent hashing exchange: recovered exchange ~s", [rabbit_misc:rs(XName)]),
            Bindings = rabbit_binding:list_for_source(XName),
            rabbit_log:debug("Consistent hashing exchange: have ~b bindings to recover for exchange ~s",
                             [length(Bindings), rabbit_misc:rs(XName)]),
            [add_binding(transaction, X, B) || B <- lists:usort(Bindings)],
            rabbit_log:debug("Consistent hashing exchange: recovered bindings for exchange ~s",
                             [rabbit_misc:rs(XName)])
    end).

create(transaction, X) ->
    maybe_initialise_hash_ring_state(transaction, X);
create(Tx, X) ->
    maybe_initialise_hash_ring_state(Tx, X).

delete(transaction, #exchange{name = Name}, _Bs) ->
    rabbit_khepri:try_mnesia_or_khepri(
      fun() ->
              mnesia:write_lock_table(?HASH_RING_STATE_TABLE),
              ok = mnesia:delete({?HASH_RING_STATE_TABLE, Name})
      end,
      fun() ->
              {ok, _} = rabbit_khepri:delete(khepri_consistent_hash_path(Name)),
              ok
      end);
delete(_Tx, _X, _Bs) ->
    ok.

policy_changed(_X1, _X2) -> ok.

add_binding(transaction, _X, #binding{source = S, destination = D, key = K}) ->
    Weight = rabbit_data_coercion:to_integer(K),
    rabbit_log:debug("Consistent hashing exchange: adding binding from "
                     "exchange ~s to destination ~s with routing key '~s'", [rabbit_misc:rs(S), rabbit_misc:rs(D), K]),
    rabbit_khepri:try_mnesia_or_khepri(
      fun() ->
              add_binding_in_mnesia(S, D, Weight)
      end,
      fun() ->
              add_binding_in_khepri(S, D, Weight)
      end);
add_binding(none, _X, _B) ->
    ok.

add_binding_in_mnesia(S, D, Weight) ->
    case mnesia:read(?HASH_RING_STATE_TABLE, S) of
        [State0 = #chx_hash_ring{bucket_map = BM0,
                                 next_bucket_number = NexN0}] ->
            NextN    = NexN0 + Weight,
            %% hi/lo bucket counters are 0-based but weight is 1-based
            Range   = lists:seq(NexN0, (NextN - 1)),
            BM      = lists:foldl(fun(Key, Acc) ->
                                          maps:put(Key, D, Acc)
                                  end, BM0, Range),
            State   = State0#chx_hash_ring{bucket_map = BM,
                                           next_bucket_number = NextN},
            ok = mnesia:write(?HASH_RING_STATE_TABLE, State, write),
            ok;
        [] ->
            maybe_initialise_hash_ring_state_in_mnesia(S),
            add_binding_in_mnesia(S, D, Weight)
    end.

add_binding_in_khepri(S, D, Weight) ->
    Path = khepri_consistent_hash_path(S),
    rabbit_khepri:transaction(
      fun() ->
              add_binding_in_khepri_tx(S, Path, D, Weight)
      end).

add_binding_in_khepri_tx(X, Path, D, Weight) ->
    case khepri_tx:get(Path) of
        {ok, #{Path := #{data := Chx0 = #chx_hash_ring{bucket_map = BM0,
                                                       next_bucket_number = NexN0}}}} ->
            NextN   = NexN0 + Weight,
            %% hi/lo bucket counters are 0-based but weight is 1-based
            Range   = lists:seq(NexN0, (NextN - 1)),
            BM      = lists:foldl(fun(Key, Acc) ->
                                          maps:put(Key, D, Acc)
                                  end, BM0, Range),
            Chx = Chx0#chx_hash_ring{bucket_map = BM,
                                     next_bucket_number = NextN},
            {ok, _} = khepri_tx:put(Path, Chx),
            ok;
        _ ->
            case khepri_tx:create(Path, #chx_hash_ring{exchange = X,
                                                       next_bucket_number = 0,
                                                       bucket_map = #{}}) of
                {ok, _} -> ok;
                {error, {mismatching_node, _}} -> ok;
                Error -> throw(Error)
            end,
            add_binding_in_khepri_tx(X, Path, D, Weight)
    end.

remove_bindings(transaction, _X, Bindings) ->
    rabbit_khepri:try_mnesia_or_khepri(
      fun() ->
              remove_bindings_in_mnesia(Bindings)
      end,
      fun() ->
              remove_bindings_in_khepri(Bindings)
      end);
remove_bindings(none, _X, Bindings) ->
    rabbit_khepri:try_mnesia_or_khepri(
      fun() ->
              rabbit_misc:execute_mnesia_transaction(
                fun() -> remove_bindings_in_mnesia(Bindings) end)
      end,
      fun() ->
              remove_bindings_in_khepri(Bindings)
      end).

remove_bindings_in_mnesia(Bindings) ->
    [remove_binding_in_mnesia(B) || B <- Bindings],
    ok.

remove_binding_in_mnesia(#binding{source = S, destination = D, key = RK}) ->
    rabbit_log:debug("Consistent hashing exchange: removing binding "
                     "from exchange '~p' to destination '~p' with routing key '~s'",
                     [rabbit_misc:rs(S), rabbit_misc:rs(D), RK]),

    case mnesia:read(?HASH_RING_STATE_TABLE, S) of
        [State0 = #chx_hash_ring{bucket_map = BM0,
                                 next_bucket_number = NexN0}] ->
            %% Buckets with lower numbers stay as is; buckets that
            %% belong to this binding are removed; buckets with
            %% greater numbers are updated (their numbers are adjusted downwards)
            BucketsOfThisBinding = maps:filter(fun (_K, V) -> V =:= D end, BM0),
            case maps:size(BucketsOfThisBinding) of
                0             -> ok;
                N when N >= 1 ->
                    KeysOfThisBinding  = lists:usort(maps:keys(BucketsOfThisBinding)),
                    LastBucket         = lists:last(KeysOfThisBinding),
                    FirstBucket        = hd(KeysOfThisBinding),
                    BucketsDownTheRing = maps:filter(fun (K, _) -> K > LastBucket end, BM0),
                    UnchangedBuckets   = maps:filter(fun (K, _) -> K < FirstBucket end, BM0),

                    %% final state with "down the ring" buckets updated
                    NewBucketsDownTheRing = maps:fold(
                                              fun(K0, V, Acc)  ->
                                                      maps:put(K0 - N, V, Acc)
                                              end, #{}, BucketsDownTheRing),
                    BM1 = maps:merge(UnchangedBuckets, NewBucketsDownTheRing),
                    NextN = NexN0 - N,
                    State = State0#chx_hash_ring{bucket_map = BM1,
                                                 next_bucket_number = NextN},

                    ok = mnesia:write(?HASH_RING_STATE_TABLE, State, write)
            end;
        [] ->
            rabbit_log:warning("Can't remove binding: hash ring state for exchange ~s wasn't found",
                               [rabbit_misc:rs(S)]),
            ok
    end.

remove_bindings_in_khepri(Bindings) ->
    Result = rabbit_khepri:transaction(
               fun() ->
                       [remove_binding_in_khepri(B) || B <- Bindings]
               end),
    [rabbit_log:warning("Can't remove binding: hash ring state for exchange ~s wasn't found",
                        [rabbit_misc:rs(X)]) || {not_found, X} <- Result],
    ok.

remove_binding_in_khepri(#binding{source = S, destination = D}) ->
    Path = khepri_consistent_hash_path(S),
    case khepri_tx:get(Path) of
        {ok, #{Path := #{data := State0 = #chx_hash_ring{bucket_map = BM0,
                                                         next_bucket_number = NexN0}}}} ->
            %% Buckets with lower numbers stay as is; buckets that
            %% belong to this binding are removed; buckets with
            %% greater numbers are updated (their numbers are adjusted downwards)
            BucketsOfThisBinding = maps:filter(fun (_K, V) -> V =:= D end, BM0),
            case maps:size(BucketsOfThisBinding) of
                0             -> ok;
                N when N >= 1 ->
                    KeysOfThisBinding  = lists:usort(maps:keys(BucketsOfThisBinding)),
                    LastBucket         = lists:last(KeysOfThisBinding),
                    FirstBucket        = hd(KeysOfThisBinding),
                    BucketsDownTheRing = maps:filter(fun (K, _) -> K > LastBucket end, BM0),
                    UnchangedBuckets   = maps:filter(fun (K, _) -> K < FirstBucket end, BM0),

                    %% final state with "down the ring" buckets updated
                    NewBucketsDownTheRing = maps:fold(
                                              fun(K0, V, Acc)  ->
                                                      maps:put(K0 - N, V, Acc)
                                              end, #{}, BucketsDownTheRing),
                    BM1 = maps:merge(UnchangedBuckets, NewBucketsDownTheRing),
                    NextN = NexN0 - N,
                    State = State0#chx_hash_ring{bucket_map = BM1,
                                                 next_bucket_number = NextN},

                    {ok, _} = khepri_tx:put(Path, State),
                    ok
            end;
        _ ->
            {not_found, S}
    end.

ring_state(VirtualHost, Exchange) ->
    Resource = rabbit_misc:r(VirtualHost, exchange, Exchange),
    rabbit_khepri:try_mnesia_or_khepri(
      fun() ->
              case mnesia:dirty_read(?HASH_RING_STATE_TABLE, Resource) of
                  []    -> {error, not_found};
                  [Row] -> {ok, Row}
              end
      end,
      fun() ->
              Path = khepri_consistent_hash_path(Resource),
              case rabbit_khepri:get(Path) of
                  {ok, #{data := State}} -> {ok, State};
                  _ -> {error, not_found}
              end
      end).

assert_args_equivalence(X, Args) ->
    rabbit_exchange:assert_args_equivalence(X, Args).

mds_migration(FeatureName, FeatureProps, IsEnabled) ->
    TablesAndOwners = [{?HASH_RING_STATE_TABLE, ?MODULE, #{}}],
    rabbit_core_ff:mds_migration(FeatureName, FeatureProps, TablesAndOwners, IsEnabled).

clear_data_in_khepri(?HASH_RING_STATE_TABLE, _ExtraArgs) ->
    case rabbit_khepri:delete(khepri_consistent_hash_path()) of
        {ok, _} ->
            ok;
        Error ->
            throw(Error)
    end.

mnesia_write_to_khepri(?HASH_RING_STATE_TABLE, #chx_hash_ring{exchange = XName} = Record,
                       _ExtraArgs) ->
    case rabbit_khepri:create(khepri_consistent_hash_path(XName), Record) of
        {ok, _} -> ok;
        {error, {mismatching_node, _}} -> ok;
        Error -> throw(Error)
    end.

mnesia_delete_to_khepri(?HASH_RING_STATE_TABLE, #chx_hash_ring{exchange = XName}, _ExtraArgs) ->
    case rabbit_khepri:delete(khepri_consistent_hash_path(XName)) of
        {ok, _} ->
            ok;
        Error ->
            throw(Error)
    end;
mnesia_delete_to_khepri(?HASH_RING_STATE_TABLE, Key, _ExtraArgs) ->
    case rabbit_khepri:delete(khepri_consistent_hash_path(Key)) of
        {ok, _} ->
            ok;
        Error ->
            throw(Error)
    end.

%%
%% Jump-consistent hashing.
%%

jump_consistent_hash(_Key, 1) ->
    0;
jump_consistent_hash(KeyList, NumberOfBuckets) when is_list(KeyList) ->
    jump_consistent_hash(hd(KeyList), NumberOfBuckets);
jump_consistent_hash(Key, NumberOfBuckets) when is_integer(Key) ->
    SeedState = rand:seed_s(?SEED_ALGORITHM, {Key, Key, Key}),
    jump_consistent_hash_value(-1, 0, NumberOfBuckets, SeedState);
jump_consistent_hash(Key, NumberOfBuckets) ->
    jump_consistent_hash(erlang:phash2(Key), NumberOfBuckets).

jump_consistent_hash_value(B, J, NumberOfBuckets, _SeedState) when J >= NumberOfBuckets ->
    B;

jump_consistent_hash_value(_B0, J0, NumberOfBuckets, SeedState0) ->
    B = J0,
    {R, SeedState} = rand:uniform_s(SeedState0),
    J = trunc((B + 1) / R),
    jump_consistent_hash_value(B, J, NumberOfBuckets, SeedState).

value_to_hash(undefined, #basic_message { routing_keys = Routes }) ->
    Routes;
value_to_hash({header, Header}, #basic_message { content = Content }) ->
    Headers = rabbit_basic:extract_headers(Content),
    case Headers of
        undefined -> undefined;
        _         -> rabbit_misc:table_lookup(Headers, Header)
    end;
value_to_hash({property, Property}, #basic_message { content = Content }) ->
    #content{properties = #'P_basic'{ correlation_id = CorrId,
                                      message_id     = MsgId,
                                      timestamp      = Timestamp }} =
        rabbit_binary_parser:ensure_content_decoded(Content),
    case Property of
        <<"correlation_id">> -> CorrId;
        <<"message_id">>     -> MsgId;
        <<"timestamp">>      ->
            case Timestamp of
                undefined -> undefined;
                _         -> integer_to_binary(Timestamp)
            end
    end.

hash_args(Args) ->
    Header =
        case rabbit_misc:table_lookup(Args, <<"hash-header">>) of
            undefined     -> undefined;
            {longstr, V1} -> {header, V1}
        end,
    Property =
        case rabbit_misc:table_lookup(Args, <<"hash-property">>) of
            undefined     -> undefined;
            {longstr, V2} -> {property, V2}
        end,
    {Header, Property}.

hash_on(Args) ->
    case hash_args(Args) of
        {undefined, undefined} -> undefined;
        {Header, undefined}    -> Header;
        {undefined, Property}  -> Property
    end.

khepri_consistent_hash_path(#exchange{name = Name}) ->
    khepri_consistent_hash_path(Name);
khepri_consistent_hash_path(#resource{virtual_host = VHost, name = Name}) ->
    [?MODULE, exchange_type_consistent_hash_ring_state, VHost, Name].

khepri_consistent_hash_path() ->
    [?MODULE, exchange_type_consistent_hash_ring_state].
