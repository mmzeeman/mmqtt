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

-module(mmqtt_connection).

-include("include/mmqtt.hrl").
-include("include/mmqtt_packet.hrl").


-export([
    handle_packet/2,
    handle_info/2,

    connect/3
]).

-record(state, {
    client_id :: binary(),

    session_pid :: pid(),

    options :: term()
}).


%% Connect

connect(#mqtt_connect{protocol_name= <<"MQTT">>, 
        protocol_version=4}=Packet, Socket, Options) ->
    mqtt_3_1_1_connect(Packet, Socket, Options);
connect(#mqtt_connect{protocol_name= <<"MQIsdp">>, 
        protocol_version=3}=Packet, Socket, Options) ->
    mqtt_3_1_connect(Packet, Socket, Options);

connect(#mqtt_connect{}, _Socket, _Options) ->
    ignore.

%% Subscribe to a topic
handle_packet(#mqtt_subscribe{}=Subscribe, #state{session_pid=Pid}=State) ->
    subscribe(Pid, Subscribe, State);

%% Publish a message
handle_packet(#mqtt_publish{}=Publish, #state{session_pid=Pid}) ->
    mmqtt_session:publish(Pid, Publish);

%% Unsubscribe from a topic
handle_packet(#mqtt_unsubscribe{}=Unsubscribe, #state{session_pid=Pid}=State) ->
    unsubscribe(Pid, Unsubscribe, State);

%% Disconnect the session
handle_packet(#mqtt_disconnect{}=Disconnect, #state{session_pid=Pid}) ->
    io:fwrite(standard_error, "disconnect: ~p~n", [Disconnect]),
    unlink(Pid),
    noreply;

%% Respond to ping packets
handle_packet(#mqtt_pingreq{}, _Args) ->
    {reply, #mqtt_pingresp{}};

%% Other packages are ignored
handle_packet(MqttPacket, Args) ->
    noreply.

%% Events
%%
handle_info({send, Msg}, Args) ->
    io:fwrite(standard_error, "handle_info: ~p, ~p~n", [Msg, Args]),
    {reply, Msg};
handle_info(Msg, Args) ->
    io:fwrite(standard_error, "handle_info: ~p, ~p~n", [Msg, Args]),
    noreply.

%% Connect

mqtt_3_1_1_connect(#mqtt_connect{client_id=ClientId, clean_session=true, will=Will}, Socket, Options) ->
    Id = case ClientId of <<>> -> make_ref(); _ -> ClientId end,

    case mmqtt_notifier:first(#is_allowed{action=connect, object=Socket}, ClientId) of
        true ->
            %% Stop and remove existing session.
            case mmqtt_session:whereis_name(Id) of
                undefined -> ok;
                Pid -> _ = mmqtt_session:stop(Pid)
            end,

            %% Start a clean session
            ok = mmqtt_session:start(ClientId, self()),
            {reply, #mqtt_connack{connect_return_code=?ACCEPTED}, #state{client_id=ClientId, options=Options}};
        _ ->
            {stop, #mqtt_connack{connect_return_code=?NOT_AUTHORIZED}}
    end.

mqtt_3_1_connect(#mqtt_connect{client_id=ClientId, clean_session=true, will=Will}, Socket, Options) ->
    Id = case ClientId of <<>> -> make_ref(); _ -> ClientId end,

    %% Stop/clean existing session
    case mmqtt_session:whereis_name(Id) of
        undefined -> ok;
        _Pid -> 
            _ = mmqtt_session:stop(Id)
    end,

    %% TODO: What should be in the callback of the session?
    {ok, SessionPid} = mmqtt_session:start(Id, {mmqtt_connection, []}),
    true = erlang:link(SessionPid),

    %% TODO: Authorization, 
    %% TODO: Monitor this connection process and add the will to the session.
    %% TODO: Monitor the session, when it crashes the connection should be stopped too.
    %% TODO: Maybe the processes should be linked instead of monitored.

    {reply, #mqtt_connack{connect_return_code=?ACCEPTED}, 
        #state{client_id=Id, session_pid=SessionPid, options=Options}}.


%%
%% Helpers
%%

subscribe(SessionPid, #mqtt_subscribe{topics=Topics, packet_identifier=PackId}, State) ->
    {ok, Reply} = mmqtt_session:subscribe(SessionPid, Topics),
    Ack = #mqtt_suback{packet_identifier=PackId, return_codes=Reply},
    {reply, Ack, State}.

unsubscribe(SessionPid, #mqtt_unsubscribe{topics=Topics, packet_identifier=PackId}, _State) ->
    _ = mmqtt_session:unsubscribe(SessionPid, Topics),
    noreply.
    
