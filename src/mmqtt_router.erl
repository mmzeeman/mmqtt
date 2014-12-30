%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% Developer of the eMQTT Code is <ery.lee@gmail.com>
%% Copyright (c) 2012 Ery Lee.  All rights reserved.
%%

%% Changed into an ets based router by:
%% Maas-Maarten Zeeman <mmzeeman@xs4all.nl>.

-module(mmqtt_router).

-include("mmqtt.hrl").
-include("mmqtt_packet.hrl").
-include("mmqtt_internal.hrl").

-ifdef(TEST).
-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").
-endif.

-behaviour(gen_server).

-export([
    start_link/0,
    topics/0,
    subscribe/2, 
    unsubscribe/2,
    publish/1,
    publish/2,
    route/2,
    match/1,
    disconnect/1
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(NODE_TABLE, mmqtt_router_node).
-define(TRIE_TABLE, mmqtt_router_trie).
-define(TOPIC_TABLE, mmqtt_router_topic).
-define(SUBSCRIBER_TABLE, mmqtt_router_subscriber).

-record(state, {}).

%%
%% Api
%%

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).


% @doc Get all topics
topics() ->
    [Name || #topic{name=Name} <- ets:tab2list(?TOPIC_TABLE)].


% @doc Subscribe to the specified topic.
subscribe(Topics, Client) when is_list(Topics) andalso is_pid(Client) ->
    gen_server:call(?MODULE, {subscribe, Topics, Client});
subscribe({Topic, Qos}, Client) when is_pid(Client) ->
    subscribe([{Topic, Qos}], Client);
subscribe(Topic, Client) ->
    subscribe([{Topic, ?QOS_0}], Client).

% @doc Unsubscribe from the specified topic.
unsubscribe(Topics, Client) when is_list(Topics) andalso is_pid(Client) ->
    gen_server:call(?MODULE, {unsubscribe, Topics, Client});
unsubscribe(Topic, Client) ->
    unsubscribe([to_binary(Topic)], Client).

% @doc Publish a message.
publish(Msg=#mqtt_publish{topic_name=Topic}) ->
    publish(Topic, Msg).

% @doc 
publish(Topic, Msg) when is_record(Msg, mqtt_publish) ->
    handle_retain(Msg),
    lists:foreach(fun(#topic{name=Name}) -> 
                route(Name, Msg) 
        end, match(Topic)).

% @doc Disconnect client
disconnect(Client) when is_pid(Client) ->
    do_down(Client).

% @doc Route message locally, should only be called by publish
route(Topic, #mqtt_publish{qos=Qos}=Msg) when is_binary(Topic) ->
    [Client ! {route, Msg#mqtt_publish{qos=route_qos(Qos, SubscriberQos)}} || 
        #subscriber{qos=SubscriberQos, client=Client} <- ets:lookup(?SUBSCRIBER_TABLE, Topic)].

% @doc route_qos(MsgQos, SubscriberQos) -> RouteQos
route_qos(0, _) -> 0; % qos0 message, 
route_qos(_, 0) -> 0; % qos0 subscriber
route_qos(_, 1) -> 1; % qos1 subscriber
route_qos(1, 2) -> 1; %
route_qos(2, 2) -> 2.

% @doc Return all
match(Topic) ->
    TrieNodes = trie_match(mmqtt_topic:words(to_binary(Topic))),
    Topics = [ets:lookup(?TOPIC_TABLE, Name) || #trie_node{topic=Name} <- TrieNodes, Name =/= undefined],
    lists:flatten(Topics).

    
%%
%% Gen-server callbacks
%%

init([]) ->
    process_flag(trap_exit, true),

    %% Create the routing tables.
    ets:new(?NODE_TABLE, [protected, named_table, {read_concurrency, true}, {keypos, 2}]),
    ets:new(?TRIE_TABLE, [protected, named_table, {read_concurrency, true}, {keypos, 2}]),
    ets:new(?TOPIC_TABLE, [protected, named_table, bag, {read_concurrency, true}, {keypos, 2}]),
    ets:new(?SUBSCRIBER_TABLE, [protected, named_table, bag, {read_concurrency, true}, {keypos, 2}]),

    lager:info("~p is started.", [?MODULE]),
    {ok, #state{}}.

handle_call({subscribe, Topics, Client}, _From, State) when is_list(Topics) ->
    _ = erlang:monitor(process, Client),
    do_subscribe(Topics, Client),
    {reply, ok, State};

handle_call({unsubscribe, Topics, Client}, _From, State) when is_list(Topics) ->
    do_unsubscribe(Topics, Client),
    {reply, ok, State};

handle_call(stop, _From, State) ->
    {stop, normal, ok, State};

handle_call(Req, _From, State) ->
    {stop, {badreq,Req}, State}.

handle_cast(Msg, State) ->
    {stop, {badmsg, Msg}, State}.

handle_info({'DOWN', _MRef, _Type, ClientPid, _Info}, State) when is_pid(ClientPid) ->
    do_down(ClientPid),
    {noreply, State};
handle_info(Info, State) ->
    lager:warning("Unexpected message: ~p", [Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%
%% Helpers
%%

handle_retain(#mqtt_publish{retain=true, payload= <<>>}=Msg) ->
    mmqtt_retain:delete(Msg);
handle_retain(#mqtt_publish{retain=true}=Msg) ->
    mmqtt_retain:insert(Msg);
handle_retain(#mqtt_publish{}) ->
    ok.

try_remove_topic(Name) ->
    case ets:member(?SUBSCRIBER_TABLE, Name) of
        false ->
            Topic = mmqtt_topic:new(Name),
            ets:delete_object(?TOPIC_TABLE, Topic),
            case ets:lookup(?TOPIC_TABLE, Name) of
                [] ->
                    trie_delete(Name);
                _ ->
                    ignore
            end;
        true -> 
            ok
        end.

trie_add(Topic) ->
    ets:insert(?TOPIC_TABLE, mmqtt_topic:new(Topic)),
    case ets:lookup(?NODE_TABLE, Topic) of
        [#trie_node{topic=undefined}=Node] ->
            ets:insert(?NODE_TABLE, Node#trie_node{topic=Topic});
        [#trie_node{topic=Topic}] ->
            ok;
        [] ->
            Triples = mmqtt_topic:triples(Topic),
            [trie_add_path(Triple) || Triple <- Triples],
            TrieNode = #trie_node{node_id=Topic, topic=Topic},
            ets:insert(?NODE_TABLE, TrieNode)
    end.

trie_delete(Topic) ->
    case ets:lookup(?NODE_TABLE, Topic) of
        [#trie_node{edge_count=0}] ->
            ets:delete(?NODE_TABLE, Topic),
            trie_delete_path(lists:reverse(mmqtt_topic:triples(Topic)));
        [TrieNode] ->
            ets:insert(?NODE_TABLE, TrieNode#trie_node{topic=Topic});
        [] -> 
            ignore
    end.

trie_add_path({Node, Word, Child}) ->
    Edge = #trie_edge{node_id=Node, word=Word},
    case ets:lookup(?NODE_TABLE, Node) of
        [#trie_node{edge_count=_Count}] ->
            case ets:lookup(?TRIE_TABLE, Edge) of
                [] ->
                    Trie = #trie{edge=Edge, node_id=Child},
                    ets:update_counter(?NODE_TABLE, Node, {#trie_node.edge_count, +1}),
                    ets:insert(?TRIE_TABLE, Trie);
                [_] ->
                    ok
            end;
        [] ->
            TrieNode = #trie_node{node_id=Node, edge_count=1},
            Trie = #trie{edge=Edge, node_id=Child},
            ets:insert(?NODE_TABLE, TrieNode),
            ets:insert(?TRIE_TABLE, Trie)
    end.

trie_delete_path([]) ->
    ok;
trie_delete_path([{NodeId, Word, _} | RestPath]) ->
    Edge = #trie_edge{node_id=NodeId, word=Word},
    ets:delete(?TRIE_TABLE, Edge),

    case ets:lookup(?NODE_TABLE, NodeId) of
        [#trie_node{edge_count=1, topic=undefined}] ->
            ets:delete(?NODE_TABLE, NodeId),
            trie_delete_path(RestPath);
        [#trie_node{edge_count=1, topic=Topic}] ->
            ets:update_counter(?NODE_TABLE, NodeId, {#trie_node.edge_count, -1}),
            case ets:lookup(?TOPIC_TABLE, Topic) of
                [] ->
                    %% This topic is gone too.
                    trie_delete(Topic);
                _ ->
                    ok
            end;
        [#trie_node{edge_count=Count}] when Count >= 1 ->
            ets:update_counter(?NODE_TABLE, NodeId, {#trie_node.edge_count, -1});

        [] ->
            throw({notfound, NodeId})
    end.

trie_match(Words) ->
    trie_match(root, Words, []).

trie_match(NodeId, [], ResAcc) ->
    Found = ets:lookup(?NODE_TABLE, NodeId),
    Found ++ 'trie_match_#'(NodeId, ResAcc);

trie_match(NodeId, [W|Words], ResAcc) ->
    lists:foldl(fun(WArg, Acc) ->
                case ets:lookup(?TRIE_TABLE, #trie_edge{node_id=NodeId, word=WArg}) of
                    [#trie{node_id=ChildId}] -> 
                        trie_match(ChildId, Words, Acc);
                    [] -> 
                        Acc
                end
        end, 'trie_match_#'(NodeId, ResAcc), [W, $+]).

'trie_match_#'(NodeId, ResAcc) ->
    case ets:lookup(?TRIE_TABLE, #trie_edge{node_id=NodeId, word=$#}) of
        [#trie{node_id=ChildId}] ->
            Found = ets:lookup(?NODE_TABLE, ChildId),
            Found ++ ResAcc;
        [] ->
            ResAcc
    end.

to_binary(L) when is_list(L) ->
    unicode:characters_to_binary(L);
to_binary(B) when is_binary(B) ->
    B.

%% Add multiple subscriptions
%%

do_subscribe([], _Client) ->
    ok;
do_subscribe([{Topic, QoS}|Topics], Client) ->
    trie_add(Topic),
    ets:insert(?SUBSCRIBER_TABLE, #subscriber{topic=Topic, qos=QoS, client=Client}),
    mmqtt_notifier:notify(#client_subscribe{topic=Topic, qos=QoS}, Client),
    do_subscribe(Topics, Client).


%% Do multiple unsubscribes
%% 

do_unsubscribe([], _Client) ->
    ok;
do_unsubscribe([Topic|Topics], Client) ->
    ets:match_delete(?SUBSCRIBER_TABLE, #subscriber{topic=Topic, client=Client, _='_'}),
    try_remove_topic(Topic),
    mmqtt_notifier:notify(#client_unsubscribe{topic=Topic}, Client),
    do_unsubscribe(Topics, Client).

%% Remove client from subscriptions
%

do_down(ClientPid) when is_pid(ClientPid) ->
    case ets:match_object(?SUBSCRIBER_TABLE, #subscriber{client=ClientPid, _='_'}) of
        [] -> ignore;
        Subs -> [begin 
                    ets:delete_object(?SUBSCRIBER_TABLE, Sub),
                    try_remove_topic(Topic),
                    mmqtt_notifier:notify(#client_unsubscribe{topic=Topic}, ClientPid)
                end || #subscriber{topic=Topic}=Sub <- Subs]
    end.

%%
%% Tests
%%

-ifdef(TEST).

-define(setup(F), {setup, fun setup/0, fun teardown/1, F}).

is_started_test_() ->
    ?setup(fun(Pid) ->
                [?_assertEqual(Pid, whereis(?MODULE))]
        end).

subscribe_unsubscribe_test_() ->
    ?setup(fun(_Pid) ->
                subscribe(<<"a/b/c">>, self()),
                subscribe(<<"a/#">>, self()),

                T1 = topics(),

                M1 = match(<<"a/c">>),
                M2 = match(<<"a/b/c">>),
                M3 = match(<<"a/b/c/d">>),
                M4 = match(<<"x/b/c/d">>),

                unsubscribe(<<"a/#">>, self()),
                T2 = topics(),

                M5 = match(<<"a/c">>),
                M6 = match(<<"a/b/c">>),

                subscribe(<<"a/+/c">>, self()),

                M7 = match(<<"a/x/c">>),
                M8 = match(<<"a/b/c">>),

                [ ?_assertEqual([#topic{name= <<"a/#">>}], M1),
                  ?_assertEqual([#topic{name= <<"a/#">>},
                                 #topic{name= <<"a/b/c">>}], lists:sort(M2)),
                  ?_assertEqual([#topic{name= <<"a/#">>}], lists:sort(M3)),
                  ?_assertEqual([], M4),
                  ?_assertEqual([], M5),
                  ?_assertEqual([#topic{name= <<"a/b/c">>}], M6),
                  ?_assertEqual([#topic{name= <<"a/+/c">>}], M7),

                  ?_assertEqual([#topic{name= <<"a/+/c">>},
                                 #topic{name= <<"a/b/c">>} ], lists:sort(M8)),

                  ?_assertEqual([<<"a/#">>, <<"a/b/c">>], lists:sort(T1)),
                  ?_assertEqual([<<"a/b/c">>], T2)
              ]
        end).

random_sub_match_test() ->
    Pid = setup(),
    try
        ?assertEqual(true, proper:quickcheck(subscribe_props(), [{to_file, user}]))
    after
        teardown(Pid)
    end,
    ok.

subscribe_props() ->
    ?FORALL(
       IntTopics,
       list(list(int())),
       begin 
           Topics = [to_topic(IntTopic, <<>>) || IntTopic <- IntTopics],


           %% Test subscribing to the topics one by one.
           subscribe_multi_props(Topics, []),

           %% Now, unsubscribe from all topics. 
           %%
           %% Because unsubscribe removes multi regestrations we have to 
           %% setify the Topics before running the test.
           unsubscribe_multi_props(setify(Topics)),

           %% Now there should be no more subscriptions
           ?assertEqual([], topics()),

           %% And we should have no more nodes and edges dangling
           ?assertEqual([], ets:tab2list(?TRIE_TABLE)),
           ?assertEqual([], ets:tab2list(?NODE_TABLE)),

           true
       end).

subscribe_multi_props([], _) ->
    ok;
subscribe_multi_props([Topic|Rest], Registered) ->
    subscribe(Topic, self()),
    NowRegistered = setify([Topic | Registered]),
    ?assertEqual(NowRegistered, setify(topics())),
    subscribe_multi_props(Rest, NowRegistered).

unsubscribe_multi_props([]) ->
    ok;
unsubscribe_multi_props([Topic|Rest]) ->
    unsubscribe(Topic, self()),
    ?assertEqual(setify(topics()), lists:sort(Rest)),
    unsubscribe_multi_props(Rest).

setify(L) ->
    S = sets:from_list(L),
    L1 = sets:to_list(S),
    lists:sort(L1).

to_topic([], <<>>) ->
    <<"#">>;
to_topic([], Topic) ->
    Topic;
to_topic([H|T], Topic) ->
    B = list_to_binary(integer_to_list(H)),
    to_topic(T, <<Topic/binary, $/, B/binary>>).


setup() ->
    {ok, Pid} = start_link(),
    Pid.

teardown(_) ->
    gen_server:call(?MODULE, stop).

-endif.

