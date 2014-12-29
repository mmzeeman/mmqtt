%% @author Maas-Maarten <mmzeeman@xs4all.nl>
%% @copyright 2014 Maas-Maarten Zeeman

%% Copyright 2014 Maas-Maarten Zeeman
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

-module(mmqtt_session).

-behaviour(gen_server).

-include("include/mmqtt_packet.hrl").

% api 
-export([
    start/4,
    stop/1,

    start_link/1,

    clean/1,
    session_id/1,
    disconnect/1,

    publish/2,
    subscribe/2,
    unsubscribe/2
]).

% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

% Process registry callbacks
-export([register_name/2, unregister_name/1, whereis_name/1, send/2]).

%%
%% The session state
%%

-record(state, {
    id :: binary(),
    connection=undefined :: undefined | pid(),
    clean_session=true :: boolean(),
    will=undefined,

    logon_state :: term(),

    sent_qos_1_2_pending_ack=[],
    recv_qos_2_pending_ack=[],

    qos_1_2_pending_trans=[],
    qos_1_pending_trans=[]
}).


%%
%% Api
%%

% @doc Start a new session
%
start(Id, CleanSession, Will, LogonState) ->
    supervisor:start_child(mmqtt_session_sup, {Id,
            {?MODULE, start_link, [[
                        {id, Id},
                        {clean_session, CleanSession},
                        {will, Will},
                        {logon_state, LogonState},
                        {connection, self()} 
                    ]]}, temporary, 5000, worker, dynamic}).

% @doc Stop a session
%
stop(Id) ->
    case supervisor:terminate_child(mmqtt_session_sup, Id) of
        ok ->
            supervisor:delete_child(mmqtt_session_sup, Id);
        {error, not_found} ->
            ok
    end.

start_link(Opts) ->
    Id = required_opt(id, Opts),
    gen_server:start_link({via, ?MODULE, Id}, ?MODULE, [Opts], []).


% @doc Clean all previously existing data for this session
%
clean(<<>>) ->
    ok;
clean(ClientId) ->
    case whereis_name(ClientId) of
        undefined -> ok;
        _Pid ->
            _ = stop(ClientId),
            ok
    end.

% @doc Get an id for this session.
% 
session_id(<<>>) ->
    %% Generate a random session id.
    Rand = base64:encode(crypto:rand_bytes(12)),
    <<"mmqtt-", Rand/binary>>;
session_id(ClientId) ->
    ClientId.

% @doc Disconnect
%
disconnect(Pid) when is_pid(Pid) ->
    gen_server:call(Pid, disconnect);
disconnect(ClientId) -> 
    gen_server:call({via, ?MODULE, ClientId}, disconnect).

% @doc Publish a message
%
publish(_ClientId, #mqtt_publish{qos=0}=Message) ->
    %% Route the message, without bothering the session process.
    mmqtt_router:publish(Message),
    noreply;
publish(Pid, #mqtt_publish{}=Message) when is_pid(Pid) ->
    gen_server:call(Pid, {publish, Message});
publish(ClientId, #mqtt_publish{}=Message) ->
    gen_server:call({via, ?MODULE, ClientId}, {publish, Message}).

% @doc Subscribe to topics
%
subscribe(Pid, Topics) when is_pid(Pid) ->
    gen_server:call(Pid, {subscribe, Topics});
subscribe(ClientId, Topics) ->
    gen_server:call({via, ?MODULE, ClientId}, {subscribe, Topics}).


% @doc Unsubscribe from topics
%
unsubscribe(Pid, Topics) when is_pid(Pid) ->
    gen_server:call(Pid, {unsubscribe, Topics});
unsubscribe(ClientId, Topics) ->
    gen_server:call({via, ?MODULE, ClientId}, {unsubscribe, Topics}).


%%
%% Name registry via gproc. 
%%

register_name(Name, Pid) when element(1, Name) =:= ?MODULE ->
    gproc:register_name({n, l, Name}, Pid);
register_name(Id, Pid) ->
    register_name(name(Id), Pid).

unregister_name(Name) when element(1, Name) =:= ?MODULE ->
    gproc:unregister_name({n, l, Name});
unregister_name(Id) ->
    unregister_name(name(Id)).

send(Name, Msg) when element(1, Name) =:= ?MODULE ->
    gproc:send({n, l, Name}, Msg);
send(Id, Msg) ->
    send(name(Id), Msg).

whereis_name(Name) when element(1, Name) =:= ?MODULE ->
    gproc:whereis_name({n, l, Name});
whereis_name(Id) ->
    whereis_name(name(Id)).

name(Ref) when is_reference(Ref) ->
    {?MODULE, Ref};
name(Bin) when is_binary(Bin) ->
    {?MODULE, Bin}.

%%
%% gen_server callbacks
%%

init([Opts]) ->
    process_flag(trap_exit, true),

    Id = proplists:get_value(id, Opts),

    %% Link to the connection, if it goes down and we have a will we
    %% have to publish it.
    Connection = required_opt(connection, Opts),
    erlang:link(Connection),

    Will = required_opt(will, Opts),
    CleanSession = required_opt(clean_session, Opts),
    LogonState = required_opt(logon_state, Opts),

    {ok, #state{id=Id, will=Will, logon_state=LogonState, 
            clean_session=CleanSession, connection=Connection}}.

%% Publish
handle_call({publish, _Msg}, _From, State) ->
    {reply, not_implemented, State};

%% Subscribe
handle_call({subscribe, Topics}, _From, State) ->
    Answer = do_subscribe(Topics),     
    {reply, {ok, Answer}, State};

%% Unsubscribe
handle_call({unsubscribe, Topics}, _From, State) ->
    Answer = do_unsubscribe(Topics),     
    {reply, {ok, Answer}, State};

handle_call(disconnect, _From, #state{}=State) ->
    %% Disconnect from the router,
    mmqtt_router:disconnect(self()),

    %% And forget the stored will.
    {reply, ok, State#state{will=undefined}};

handle_call(Msg, _From, State) ->
    {stop, {unexpected_msg, Msg}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({route, #mqtt_publish{}=Msg}, #state{connection=Pid}=State) ->
    case Pid of
        undefined ->
            lager:info("no connection: ~p", [Msg]);
        _ ->
            Pid ! {send, Msg}
    end,

    {noreply, State};


handle_info({'EXIT', Pid, _Reason}, #state{connection=Pid, will=undefined}=State) ->
    %% Connection exit, but no stored will, ignore
    {noreply, State#state{connection=undefined}};
handle_info({'EXIT', Pid, Reason}, #state{connection=Pid, will=#mqtt_will{retain=Retain, qos=QoS, 
            topic=Topic, message=Message}}=State) ->
    lager:info("Connection exit, reason(~p), publishing last will.", [Reason]),
    Msg = #mqtt_publish{dup=0, qos=QoS, retain=Retain, topic_name=Topic, payload=Message},
    mmqtt_router:publish(Msg),
    {noreply, State#state{connection=undefined, will=undefined}};

handle_info(Msg, #state{}=State) ->
    lager:info("session: ~p (~p)", [Msg, State]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%
%% Helpers
%%

do_subscribe(Topics) ->
    %% TODO acl check via notify for subscribe
    %% Check topics..
    ok = mmqtt_router:subscribe(Topics, self()),
    % send the code back for each subscription
    [QoS || {_Top, QoS} <- Topics].

do_unsubscribe(Topics) ->
    mmqtt_router:unsubscribe(Topics, self()).

required_opt(Name, Opts) ->
    case proplists:lookup(Name, Opts) of
        none ->
            throw(badarg);
        {Name, Value} -> 
            Value
    end.

valid_callback(Mod) ->
    lists:member({handle_event, 3}, Mod:module_info(exports)).

