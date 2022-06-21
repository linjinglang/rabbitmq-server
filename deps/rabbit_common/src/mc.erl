
-module(mc).

-export([
         init/3
         ]).

-define(NIL, []).


-type ann_key() :: atom() | string().
-type ann_value() :: atom() | string() | integer() | float().
-type protocol() :: module().
-type annotations() :: #{ann_key() => ann_value()}.

%% the protocol module must implement the mc behaviour
-record(cfg, {protocol :: module()}).

-record(?MODULE, {cfg :: #cfg{},
                  %% protocol specific data term
                  data :: term(),
                  %% any annotations done by the broker itself
                  %% such as recording the exchange / routing keys used
                  annotations = #{} :: annotations()}).

-opaque state() :: #?MODULE{}.

-export_type([
              state/0
              ]).

-type proto_state() :: term().
-type property() :: user_id |
                    reply_to |
                    message_id |
                    ttl |
                    priority |
                    durable
                    . %% etc
-type property_value() :: undefined |
                          string() |
                          integer() |
                          float() |
                          boolean().



%% behaviour callbacks for protocol specific implementation
-callback init(term()) -> proto_state().

-callback size(proto_state()) ->
    {MetadataSize :: non_neg_integer(),
     PayloadSize :: non_neg_integer()}.

-callback set_property(property(), proto_state()) ->
    proto_state().

%% strictly speaking properties ought to be immutable
-callback get_property(property(), proto_state()) ->
    {property_value(), proto_state()}.





-spec init(protocol(), term(), annotations()) -> state().
init(Proto, Data, Anns)
  when is_atom(Proto)
       andalso is_map(Anns) ->
    Cfg = #cfg{protocol = Proto},
    #?MODULE{cfg = Cfg,
             data = Data,
             annotations = Anns}.


-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.
