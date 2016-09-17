%% @author Maas-Maarten <mmzeeman@xs4all.nl>
%% @copyright 2014 Maas-Maarten Zeeman

%% @doc: MMQTT connection implementation
%%
%% A mmqtt_protocol process blocks in mmqtt_tcp:accept/2 until a client
%% connects. It then handles requests on that connection until it's
%% closed either by the client timing out or explicitly by the user.

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

-module(mmqtt_protocol).

%% mqtt network connection fsm

-include("include/mmqtt_packet.hrl").

%% API
-export([start_link/4]).

%% Exported for looping with a fully-qualified module name
-export([
    accept/4, 

    connecting_state/3, connecting_state/4,
    connected_state/5
    ]).

-type callback() :: {module(), atom()}.

-record(alive_check, {
    check_interval :: pos_integer(),
    timer_ref :: reference(),
    last_packet_received :: erlang:timestamp()
}).

-record(state, {
    alive_check = undefined :: undefined | #alive_check{},

    dispatch :: module(),
    context :: term()
}).

-spec start_link(pid(), mmqtt_tcp:socket(), proplists:proplist(), callback()) -> pid().
start_link(Server, ListenSocket, Options, Callback) ->
    proc_lib:spawn_link(?MODULE, accept, [Server, ListenSocket, Options, Callback]).

-spec accept(pid(), mmqtt_tcp:socket(), proplists:proplist(), callback()) -> ok.

-define(IS_C2S_PACKET(R), (is_record(R, mqtt_publish) orelse 
    is_record(R, mqtt_subscribe) orelse 
    is_record(R, mqtt_unsubscribe) orelse 
    is_record(R, mqtt_pingreq) orelse 
    is_record(R, mqtt_disconnect))).

%% @doc: Accept on the socket until a client connects. Handles the
%% request, then loops if we're using keep alive or chunked
%% transfer. If accept doesn't give us a socket within a configurable
%% timeout, we loop to allow code upgrades of this module.
accept(Server, ListenSocket, Options, Callback) ->
    case catch mmqtt_tcp:accept(ListenSocket, accept_timeout(Options)) of
        {ok, Socket} ->
            gen_server:cast(Server, accepted),
            ?MODULE:connecting_state(Socket, Options, Callback);
        {error, timeout} ->
            ?MODULE:accept(Server, ListenSocket, Options, Callback);
        {error, econnaborted} ->
            ?MODULE:accept(Server, ListenSocket, Options, Callback);
        {error, closed} ->
            ok;
        {error, Other} ->
            exit({error, Other})
    end.

%%
%% Connecting state
%%

connecting_state(Socket, Options, Callback) ->
    connecting_state(Socket, mmqtt_packet:decode(<<>>), Options, Callback).

connecting_state(Socket, {more, _}=More, Options, {Mod, Args}=Callback) ->
    %% Socket in passive state.
    case mmqtt_tcp:recv(Socket, 0, connect_timeout(Options)) of
        {ok, Data} ->
            ?MODULE:connecting_state(Socket, mmqtt_packet:decode(Data, More), Options, Callback);
        {error, timeout} ->
            handle_event(Mod, connect_timeout, [], Args),
            mmqtt_tcp:close(Socket),
            exit(normal);
        {error, Closed} when Closed =:= closed orelse Closed =:= enotconn ->
            handle_event(Mod, connection_closed, [], Args),
            mmqtt_tcp:close(Socket),
            exit(normal)
    end;

connecting_state(Socket, {ok, #mqtt_connect{}=Connect, Rest}, Options, {Mod, Args}=Callback) ->
    handle_event(Mod, in_packet, [Connect], Args),
    case handle_connect(Mod, Connect, Socket, Args) of
        {ok, State} -> 
            handle_event(Mod, connected, [], Args),
            ?MODULE:connected_state(Socket, mmqtt_packet:decode(Rest), Options, Callback, State);
        {stop, Reason} ->
            mmqtt_tcp:close(Socket),
            exit(Reason)
    end;

connecting_state(Socket, {ok, MqttPacket, _Rest}, _Options, {Mod, Args}) ->
    handle_event(Mod, protocol_error, [MqttPacket], Args),
    mmqtt_tcp:close(Socket),
    exit(normal);

connecting_state(Socket, {error, _}=Error, _Options, {Mod, Args}) ->
    handle_event(Mod, packet_parse_error, [Error], Args),
    mmqtt_tcp:close(Socket),
    exit(normal).

%% 
%% Connected State
%%

connected_state(Socket, {more, _}=More, Options, {Mod, Args}=Callback, #state{dispatch=Dispatch, context=Context}=State) ->
    mmqtt_tcp:setopts(Socket, [{active, once}]),
    {Ok, Passive, Closed, Error} = mmqtt_tcp:messages(Socket),
    receive
        {Ok, _S, Data} ->
            ?MODULE:connected_state(Socket, mmqtt_packet:decode(Data, More), Options, Callback, State); 
        {Passive, _S} ->
            %% The socket was switched to passive mode, retry.
            ?MODULE:connected_state(Socket, More, Options, Callback, State); 
        {Closed, _S} ->
            handle_event(Mod, connection_closed, [], Args),
            exit(normal);
        {Error, _S, Reason} ->
            handle_event(Mod, connection_error, [Reason], Args),
            exit(normal);
        check_alive ->
            case State#state.alive_check of
                undefined ->
                    ?MODULE:connected_state(Socket, More, Options, Callback, State); 
                #alive_check{check_interval=Interval, last_packet_received=LastPacket}=AliveCheck ->
                    case timer:now_diff(os:timestamp(), LastPacket) of
                        Diff when Diff div 1000000 > Interval ->
                            handle_event(Mod, connection_timeout, [], Args),
                            exit(normal);
                        _ ->
                            TRef = erlang:send_after(timer:seconds(Interval), self(), check_alive),
                            AliveCheck1 = AliveCheck#alive_check{timer_ref=TRef},
                            ?MODULE:connected_state(Socket, More, Options, Callback, 
                                State#state{alive_check=AliveCheck1})
                    end
            end;
        Message ->
            handle_event(Mod, in_message, [Message], Args),
            case handle_info(Dispatch, Socket, Message, Context) of
                {ok, Context1} ->
                    connected_state(Socket, More, Options, Callback, State#state{context=Context1});
                close ->
                    mmqtt_tcp:close(Socket),
                    exit(normal)
            end
    end;

connected_state(Socket, {error, _}=Error, _Options, {Mod, Args}, _State) ->
    handle_event(Mod, packet_parse_error, [Error], Args),
    mmqtt_tcp:close(Socket),
    exit(normal);

connected_state(Socket, {ok, Packet, Rest}, Options, {Mod, Args}=Callback, #state{dispatch=Dispatch, 
        context=Context}=State) when ?IS_C2S_PACKET(Packet) ->
    handle_event(Mod, in_packet, [Packet], Args),
    case handle_packet(Dispatch, Socket, Packet, Context) of
        {ok, Context1} ->
            State1 = case State#state.alive_check of
                undefined ->
                    State#state{context=Context1};
                AliveCheck ->
                    State#state{context=Context1, 
                        alive_check=AliveCheck#alive_check{last_packet_received=os:timestamp()}}
            end,
            connected_state(Socket, mmqtt_packet:decode(Rest), Options, Callback, State1);
        {stop, Reason} -> 
            mmqtt_tcp:close(Socket),
            exit(Reason)
    end;
connected_state(Socket, {ok, Packet, _Rest}, _Options, {Mod, Args}, _State) ->
    handle_event(Mod, protocol_error, [Packet], Args),
    mmqtt_tcp:close(Socket),
    exit(normal).
            
%%
%% Helpers
%%

accept_timeout(Opts) -> 
    proplists:get_value(accept_timeout, Opts).
connect_timeout(Opts) -> 
    proplists:get_value(connect_timeout, Opts).

handle_connect(Mod, Packet, Socket, Args) ->
    try Mod:connect(Packet, Socket, Args) of
        {{reply, #mqtt_connack{}=Reply, Context}, Dispatch} -> 
            State = case Packet#mqtt_connect.keep_alive of
                0 -> #state{};
                KeepAlive ->
                    CheckInterval = KeepAlive + KeepAlive div 2,
                    TRef = erlang:send_after(timer:seconds(CheckInterval), self(), check_alive),
                    AliveCheck = #alive_check{check_interval=CheckInterval, 
                        timer_ref=TRef, last_packet_received=os:timestamp()},
                    #state{alive_check=AliveCheck}
            end,
            ok = mmqtt_tcp:send(Socket, mmqtt_packet:encode(Reply)),
            {ok, State#state{dispatch=Dispatch, context=Context}};
        {{stop, Reason}, _Dispatch} -> 
            ok = mmqtt_tcp:send(Socket, 
                mmqtt_packet:encode(#mqtt_connack{connect_return_code=?UNACCEPTABLE_PROTOCOL_VERSION})),
            {stop, Reason};
        {{stop, Reason, #mqtt_connack{}=Reply}, _Dispatch} -> 
            ok = mmqtt_tcp:send(Socket, mmqtt_packet:encode(Reply)),
            {stop, Reason} 
    catch 
        throw:Exc ->
            handle_event(Mod, connect_throw, [Packet, Exc, erlang:get_stacktrace()], Args),
            {stop, normal};
        error:Error ->
            handle_event(Mod, connect_error, [Packet, Error, erlang:get_stacktrace()], Args),
            {stop, normal};
        exit:Exit ->
            handle_event(Mod, connect_exit, [Packet, Exit, erlang:get_stacktrace()], Args),
            {stop, normal} 
    end.


handle_packet(Dispatch, Socket, Packet, Context) ->
    try Dispatch:handle_packet(Packet, Context) of
        noreply ->
            {ok, Context};
        {noreply, Context1} -> 
            {ok, Context1};
        {reply, Reply} -> 
            ok = mmqtt_tcp:send(Socket, mmqtt_packet:encode(Reply)),
            {ok, Context};
        {reply, Reply, Context1} -> 
            ok = mmqtt_tcp:send(Socket, mmqtt_packet:encode(Reply)),
            {ok, Context1};
        {stop, _Reason}=Stop -> 
            Stop;
        {stop, _Reason, _Context1}=Stop -> 
            Stop
    catch 
        throw:Exc ->
            handle_event(Dispatch, packet_throw, [Packet, Exc, erlang:get_stacktrace()], Context),
            {stop, normal, Context};
        error:Error ->
            handle_event(Dispatch, packet_error, [Packet, Error, erlang:get_stacktrace()], Context),
            {stop, normal, Context};
        exit:Exit ->
            handle_event(Dispatch, packet_exit, [Packet, Exit, erlang:get_stacktrace()], Context),
            {stop, normal, Context}
    end.

handle_info(Dispatch, Socket, Message, Context) ->
    try Dispatch:handle_info(Message, Context) of
        noreply ->
            {ok, Context};
        {noreply, Context1} -> 
            {ok, Context1};
        {reply, Reply} ->
            ok = mmqtt_tcp:send(Socket, mmqtt_packet:encode(Reply)),
            {ok, Context};
        {reply, Reply, Context1} -> 
            ok = mmqtt_tcp:send(Socket, mmqtt_packet:encode(Reply)),
            {ok, Context1};
        {stop, _Reason, _Context}=Stop ->
            Stop;
        {stop, Reason, Packet, Context1} ->
            ok = mmqtt_tcp:send(Socket, mmqtt_packet:encode(Packet)),
            {stop, Reason, Context1}
    catch 
        throw:Exc ->
            handle_event(Dispatch, info_throw, [Message, Exc, erlang:get_stacktrace()], Context),
            {stop, normal, Context};
        error:Error ->
            handle_event(Dispatch, info_error, [Message, Error, erlang:get_stacktrace()], Context),
            {stop, normal, Context};
        exit:Exit ->
            handle_event(Dispatch, info_exit, [Message, Exit, erlang:get_stacktrace()], Context),
            {stop, normal, Context}
    end.

handle_event(Mod, Name, EventArgs, Args) ->
    try
        _ = Mod:handle_event(Name, EventArgs, Args)
    catch
        EvClass:EvError ->
            error_logger:error_msg("~p:handle_event/3 crashed ~p:~p~n~p",
                [Mod, EvClass, EvError, erlang:get_stacktrace()])
    end.


%%
%% UNIT TESTS
%%

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

-endif.
