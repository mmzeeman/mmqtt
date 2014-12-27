%% @author Maas-Maarten <mmzeeman@xs4all.nl>
%% @copyright 2014 Maas-Maarten Zeeman

%% @doc mmqtt packet enconder and decoder

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

-module(mmqtt_packet).

-export([decode/1, decode/2]).
-export([encode/1]).

-include("../include/mmqtt_packet.hrl").

% The mqtt says we MUST accept client-ids of 23 long and may reject > 23
% 255 seems reasonable.
-define(CLIENT_ID_MAXLEN, 255).

-define(MAX_LEN, 16#fffffff).
-define(HIGHBIT, 2#10000000).
-define(LOWBITS, 2#01111111).

-type mqtt_connect() :: record(mqtt_connect).
-type mqtt_connack() :: record(mqtt_connack).
-type mqtt_publish() :: record(mqtt_publish).
-type mqtt_puback() :: record(mqtt_puback).
-type mqtt_pubrec() :: record(mqtt_pubrec).
-type mqtt_pubrel() :: record(mqtt_pubrel).
-type mqtt_pubcomp() :: record(mqtt_pubcomp).
-type mqtt_subscribe() :: record(mqtt_subscribe).
-type mqtt_suback() :: record(mqtt_suback).
-type mqtt_unsubscribe() :: record(mqtt_unsubscribe).
-type mqtt_unsuback() :: record(mqtt_unsuback).
-type mqtt_pingreq() :: record(mqtt_pingreq).
-type mqtt_pingresp() :: record(mqtt_pingresp).
-type mqtt_disconnect() :: record(mqtt_disconnect).

-type mqtt_packet() :: mqtt_connect() | mqtt_connack() | 
    mqtt_publish() | mqtt_puback() | mqtt_pubrec() | mqtt_pubrel() | mqtt_pubcomp() | 
    mqtt_subscribe() | mqtt_suback() | 
    mqtt_unsubscribe() | mqtt_unsuback() | 
    mqtt_pingreq() | mqtt_pingresp() | 
    mqtt_disconnect().

-export_type([mqtt_packet/0]).

%%
%% Api
%%

-spec decode(binary()) -> {done, mqtt_packet(), binary()} |
    {more, term()} |
    {error, term()}.
% @doc Decode data into a mqtt_packet
decode(Data) ->
    decode(Data, decode_init()).

decode(Data, {more, Fun}) ->
    case catch Fun(Data) of
        {done, Packet, Rest} -> {ok, Packet, Rest};
        {more, _}=More -> More;
        {error, _}=Error -> Error;
        {'EXIT', Error} -> {error, Error}
    end.


%% @doc Encode a mqtt packet to bytes
encode(#mqtt_connack{session_present=SessionPresent, 
        connect_return_code=ConnectReturnCode}) ->
    SP = to_flag(SessionPresent),
    encode(?CONNACK, {0,0,0,0}, <<0:7, SP:1, ConnectReturnCode:8>>);

encode(#mqtt_publish{dup=Dup, qos=QoS, retain=Retain, packet_identifier=Pi, 
        topic_name=Topic, payload=Payload}) ->
    {F2, F3} = case QoS of
        0 -> {0,0};
        1 -> {0,1};
        2 -> {1,0}
    end,
    Msg = case Pi of
        undefined ->
            <<Topic/binary, Payload/binary>>;
        _ ->
            <<Topic/binary, Pi:16, Payload/binary>>
    end,
    encode(?PUBLISH, {to_flag(Dup), F2, F3, to_flag(Retain)}, Msg);

encode(#mqtt_puback{packet_identifier=Pi}) ->
    encode(?PUBACK, {0,0,0,0}, <<Pi:16>>); 

encode(#mqtt_pubrec{packet_identifier=Pi}) ->
    encode(?PUBREC, {0,0,0,0}, <<Pi:16>>); 

encode(#mqtt_pubrel{packet_identifier=Pi}) ->
    encode(?PUBREL, {0,0,0,0}, <<Pi:16>>); 

encode(#mqtt_pubcomp{packet_identifier=Pi}) ->
    encode(?PUBCOMP, {0,0,0,0}, <<Pi:16>>); 

encode(#mqtt_subscribe{}) ->
    todo;

encode(#mqtt_suback{packet_identifier=Pi, return_codes=Codes}) ->
    BinCode = encode_suback_codes(Codes, <<>>),
    encode(?SUBACK, {0,0,0,0}, <<Pi:16, BinCode/binary>>); 

encode(#mqtt_unsubscribe{}) ->
    todo;

encode(#mqtt_unsuback{packet_identifier=Pi}) ->
    encode(?UNSUBACK, {0,0,0,0}, <<Pi:16>>); 

encode(#mqtt_pingreq{}) ->
    encode(?PINGREQ, {0,0,0,0}, <<>>);

encode(#mqtt_pingresp{}) ->
    encode(?PINGRESP, {0,0,0,0}, <<>>);

encode(#mqtt_disconnect{}) ->
    encode(?DISCONNECT, {0,0,0,0}, <<>>).
    

encode(Code, {F1, F2, F3, F4}, Binary) ->
    Len = size(Binary),
    BinLen = bin_len(Len),
    <<Code:4, F1:1, F2:1, F3:1, F4:1, BinLen/binary, Binary/binary>>.
    

bin_len(N) when N =< ?LOWBITS ->
    <<0:1, N:7>>;
bin_len(N) ->
    <<1:1, (N rem ?HIGHBIT):7, (bin_len(N div ?HIGHBIT))/binary>>.

%%
%%
%%

decode_init() -> 
    {more, fun decode_fixed_header/1}.

%% Fixed header
decode_fixed_header(<<>>) ->
    {more, fun decode_fixed_header/1};
decode_fixed_header(<<PacketType:4, F1:1, F2:1, F3:1, F4:1, Rest/binary>>) ->
    decode_remaining_length(Rest, PacketType, {F1, F2, F3, F4}). 

%% Variable length header
decode_remaining_length(<<>>, PacketType, Flags) ->
    {more, fun(Data) -> 
                decode_remaining_length(Data, PacketType, Flags) 
        end};

%% @todo proper continuation
decode_remaining_length(<<0:1, RemainingLength:7, Rest/binary>>, PacketType, Flags) ->
    decode_packet(Rest, PacketType, Flags, RemainingLength);
decode_remaining_length(<<1:1, X1:7, 0:1, L:7, Rest/binary>>, PacketType, Flags) ->
    decode_packet(Rest, PacketType, Flags, L + 128 * X1);
decode_remaining_length(<<1:1, X2:7, 1:1, X1:7, 0:1, L:7, Rest/binary>>, PacketType, Flags) ->
    decode_packet(Rest, PacketType, Flags, X2 + 128 * (L + 128 * X1));
decode_remaining_length(<<_X4:8, _X3:8, _X2:8, _X1:8, _Rest/binary>>, _PacketType, _Flags) ->
    exit(not_yet_implemented).


%%
decode_packet(_, 0, _, _) ->
    exit(reserved_packet_type);
decode_packet(_, 15, _, _) ->
    exit(reserved_packet_type);

decode_packet(Data, PacketType, Flags, RLength) when size(Data) < RLength ->
    {more, fun(D) ->
                decode_packet(<<Data/binary, D/binary>>, PacketType, Flags, RLength)
        end};
decode_packet(Data, PacketType, Flags, RLength) when size(Data) >= RLength ->
    <<PacketData:RLength/binary, Rest/binary>> = Data,
    {done, decode_packet(PacketType, Flags, PacketData), Rest}. 

%% @doc Decode a MQTT packet.
decode_packet(?CONNECT, {0,0,0,0}, 
    <<ProtocolNameLen:16, ProtocolName:ProtocolNameLen/binary, 
    ProtocolVersion:8, 
    GotUserName:1, GotPassword:1, WillRetain:1, WillQoS:2, GotWill:1, CleanSession:1, 0:1,
    KeepAlive:16, Payload/binary>>) -> 

    <<ClientIdLen:16, ClientId:ClientIdLen/binary, Rest/binary>> = Payload,
    case ClientIdLen =< ?CLIENT_ID_MAXLEN of
        true -> ok;
        false -> exit(client_id_too_long)
    end,

    {Will, Rest3} = case GotWill of
        1 ->
            <<TopicLen:16, Topic:TopicLen/binary, Rest1/binary>> = Rest,
            <<MessageLen:16, Message:MessageLen/binary, Rest2/binary>> = Rest1,
            {#mqtt_will{topic=Topic, 
                message=Message, 
                retain=to_boolean(WillRetain), 
                qos=WillQoS}, Rest2};
        0 -> 
            {undefined, Rest}
    end,

    case {GotUserName, GotPassword} of
        {0, 0} -> ok;
        {1, 1} -> ok;
        {1, 0} -> ok;
        {0, 1} -> exit(no_username)
    end,

    {UserName, Rest5} = case GotUserName of
        1 -> 
            <<NameLen:16, Name:NameLen/binary, Rest4/binary>> = Rest3,
            {Name, Rest4};
        0 ->
            {undefined, Rest3}
    end,

    {Password, <<>>} = case GotPassword of
        1 -> 
            <<PwLen:16, Pw:PwLen/binary, Rest6/binary>> = Rest5,
            {Pw, Rest6};
        0 ->
            {undefined, Rest5}
    end,

    #mqtt_connect{
        protocol_name=ProtocolName,
        protocol_version=ProtocolVersion,
        client_id=ClientId,
        username=UserName,
        password=Password,
        will=Will,
        clean_session=to_boolean(CleanSession),
        keep_alive=KeepAlive};
decode_packet(?CONNACK, {0,0,0,0}, <<0:7, SP:1, ConnectReturnCode:8>>) -> 
    #mqtt_connack{session_present=to_boolean(SP), 
        connect_return_code=ConnectReturnCode};
decode_packet(?PUBLISH, {Dup, QoS2, QoS1, Retain}, 
    <<TopicLen:16, Topic:TopicLen/binary, Rest/binary>>) ->

    QoS = to_qos(QoS2, QoS1),
    case {QoS, Dup} of
        {0, 1} -> exit(wrong_dup_flag);
        _ -> ok
    end,

    {PacketIdentifier, Payload} = case QoS of
        0 ->
            {undefined, Rest};
        _ ->
            <<PI:16, Pl/binary>> = Rest,
            {PI, Pl}
    end,

    #mqtt_publish{dup=to_boolean(Dup), 
        qos=QoS, 
        retain=to_boolean(Retain),
        topic_name=Topic,
        packet_identifier=PacketIdentifier,
        payload=Payload
    };
decode_packet(?PUBACK, {0,0,0,0}, <<PacketIdentifier:16>>) -> 
    #mqtt_puback{packet_identifier=PacketIdentifier};
decode_packet(?PUBREC, {0,0,0,0}, <<PacketIdentifier:16>>) -> 
    #mqtt_pubrec{packet_identifier=PacketIdentifier};
decode_packet(?PUBREL, {0,0,1,0}, <<PacketIdentifier:16>>) -> 
    #mqtt_pubrel{packet_identifier=PacketIdentifier};
decode_packet(?PUBCOMP, {0,0,0,0}, <<PacketIdentifier:16>>) -> 
    #mqtt_pubcomp{packet_identifier=PacketIdentifier};
decode_packet(?SUBSCRIBE, {0,0,1,0}, <<PacketIdentifier:16, Topics/binary>>) -> 
    #mqtt_subscribe{
        packet_identifier=PacketIdentifier,
        topics=decode_subscribe_topics(Topics, [])};
decode_packet(?SUBACK, {0,0,0,0}, <<PacketIdentifier:16>>) -> 
    #mqtt_suback{packet_identifier=PacketIdentifier};
decode_packet(?UNSUBSCRIBE, {0,0,1,0}, <<PacketIdentifier:16, Topics/binary>>) -> 
    #mqtt_unsubscribe{
        packet_identifier=PacketIdentifier,
        topics=decode_unsubscribe_topics(Topics, [])};
decode_packet(?UNSUBACK, {0,0,0,0}, <<PacketIdentifier:16>>) -> 
    #mqtt_unsuback{packet_identifier=PacketIdentifier};
decode_packet(?PINGREQ, {0,0,0,0}, <<>>) -> 
    #mqtt_pingreq{};
decode_packet(?PINGRESP, {0,0,0,0}, <<>>) -> 
    #mqtt_pingresp{};
decode_packet(?DISCONNECT, {0,0,0,0}, <<>>) -> 
    #mqtt_disconnect{};
decode_packet(Type, Flags, Data) ->
    exit({malformed_packet, Type, Flags, Data}).


% @doc Decode a list of topic filters for subscribe.
decode_subscribe_topics(<<>>, Acc) ->
    lists:reverse(Acc);
decode_subscribe_topics(<<TopicFilterLen:16, TopicFilter:TopicFilterLen/binary,
        0:6, QoS2:1, QoS1:1, Rest/binary>>, Acc) ->
    decode_subscribe_topics(Rest, [{TopicFilter, to_qos(QoS2, QoS1)} | Acc]);
decode_subscribe_topics(_, _Acc) ->
    exit(malformed_subscribe_topics).

% @doc Decode a list of topic filters for unsubscribe
decode_unsubscribe_topics(<<>>, Acc) ->
    lists:reverse(Acc);
decode_unsubscribe_topics(<<TopicFilterLen:16, TopicFilter:TopicFilterLen/binary, 
        Rest/binary>>, Acc) ->
    decode_unsubscribe_topics(Rest, [TopicFilter | Acc]);
decode_unsubscribe_topics(_, _Acc) ->
    exit(malformed_unsubscribe_topics).

%%
%% Helpers
%%

to_boolean(0) -> false;
to_boolean(1) -> true.

to_flag(false) -> 0;
to_flag(true) -> 1.

to_qos(0,0) -> 0;
to_qos(0,1) -> 1;
to_qos(1,0) -> 2;
to_qos(1,1) -> exit(reserved_qos).

encode_suback_codes([], Encoded) -> Encoded;
encode_suback_codes([Code|Rest], Encoded) ->
    encode_suback_codes(Rest, <<Encoded/binary, Code:8>>).

%%
%% Tests
%%

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

%% Test fixtures taken from:
%% https://github.com/roberbotto/mqttsn-gw/blob/master/server/mqtt/test/connection.parse.js

connect_test() ->
    Packet = <<16, 18, %% Header
      0, 6, %% Protocol id length
      77, 81, 73, 115, 100, 112, %% Protocol id
      3, %% Protocol version
      0, %% Connect flags
      0, 30, %% Keepalive
      0, 4, %% Client id length
      116, 101, 115, 116>>, %% Client id

    ?assertEqual({ok, #mqtt_connect{protocol_name= <<"MQIsdp">>,
            protocol_version=3,
            client_id= <<"test">>, 
            keep_alive=30, 
            clean_session=false}, <<>>}, decode(Packet)),

    ok.

connect_all_fields_test() ->
    Packet = << 16, 54, %% Header
        0, 6, %% Protocol id length
        77, 81, 73, 115, 100, 112, %% Protocol id
        3, %% Protocol version
        246, %% Connect flags
        0, 30, %% Keepalive
        0, 4, %% Client id length
        116, 101, 115, 116, %% Client id
        0, 5, %% will topic length
        116, 111, 112, 105, 99, %% will topic
        0, 7, %% will payload length
        112, 97, 121, 108, 111, 97, 100, %% will payload
        0, 8, %% username length
        117, 115, 101, 114, 110, 97, 109, 101, %% username
        0, 8, %% password length
        112, 97, 115, 115, 119, 111, 114, 100>>, %% password

    ?assertEqual({ok, #mqtt_connect{protocol_name= <<"MQIsdp">>,
            protocol_version=3,
            client_id= <<"test">>, 
            keep_alive=30, 
            will=#mqtt_will{topic= <<"topic">>, 
                qos=2, 
                message= <<"payload">>, 
                retain=true },
            username= <<"username">>,
            password= <<"password">>,
            clean_session=true}, <<>>}, decode(Packet)),
    ok.

connect_binary_username_password_test() ->
    Packet = << 16, 28, %% Header
        0, 6, %% Protocol id length
        77, 81, 73, 115, 100, 112, %% Protocol id
        3, %% Protocol version
        192, %% Connect flags
        0, 30, %% Keepalive
        0, 4, %%Client id length
        116, 101, 115, 116, %% Client id
        0, 3, %% username length
        12, 13, 14, %% username
        0, 3, %% password length
        15, 16, 17 >>, %%password

    ?assertEqual({ok, #mqtt_connect{protocol_name= <<"MQIsdp">>,
            protocol_version=3,
            client_id= <<"test">>, 
            keep_alive=30, 
            will=undefined, 
            username= <<12, 13, 14>>,
            password= <<15, 16, 17>>,
            clean_session=false}, <<>>}, decode(Packet)),

    ok.

connack_test() ->
    ?assertEqual({ok, #mqtt_connack{session_present=false, 
            connect_return_code=0}, <<>>}, decode(<<32,2,0,0>>)),

    ?assertEqual({ok, #mqtt_connack{session_present=false,
             connect_return_code=5}, <<>>}, decode(<<32,2,0,5>>)),

    ok.

publish_test() ->
    Packet = <<48, 10, %% Header
        0, 4, %% Topic length
        116, 101, 115, 116, %% Topic (test)
        116, 101, 115, 116>>, %% Payload (test)

    ?assertEqual({ok, #mqtt_publish{dup=false, 
                qos=0, 
                retain=false,
                packet_identifier=undefined,
                topic_name= <<"test">>,
                payload= <<"test">>}, <<>>}, decode(Packet)),

    ok.

publish_qos2_test() ->
    Packet = << 61, 12, %% Header
        0, 4, %% Topic length
        116, 101, 115, 116, %% Topic
        0, 10, %% Message id
        116, 101, 115, 116 >>, %% Payload

    ?assertEqual({ok, #mqtt_publish{dup=true,
                qos=2,
                retain=true,
                packet_identifier=10,
                topic_name= <<"test">>,
                payload= <<"test">>}, <<>>}, decode(Packet)),

    ok.

empty_publish_test() ->
    Packet = <<48, 6, %% Header
        0, 4, %% Topic length
        116, 101, 115, 116 %% Topic
        >>, %% Empty payload

    ?assertEqual({ok, #mqtt_publish{dup=false,
                qos=0,
                retain=false,
                packet_identifier=undefined,
                topic_name= <<"test">>,
                payload= <<>>}, <<>>}, decode(Packet)),

    ok.


-endif.
