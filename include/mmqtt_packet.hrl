%%
%% MQTT Constants
%%

-define(CONNECT, 1).
-define(CONNACK, 2).

-define(PUBLISH, 3).
-define(PUBACK, 4).
-define(PUBREC, 5).
-define(PUBREL, 6).
-define(PUBCOMP, 7).

-define(SUBSCRIBE, 8).
-define(SUBACK, 9).

-define(UNSUBSCRIBE, 10).
-define(UNSUBACK, 11).

-define(PINGREQ, 12).
-define(PINGRESP, 13).

-define(DISCONNECT, 14).

% Connack Return Codes
-define(ACCEPTED, 0).
-define(UNACCEPTABLE_PROTOCOL_VERSION, 1).
-define(IDENTIFIER_REJECTED, 2).
-define(SERVER_UNAVAILABLE, 3).
-define(BAD_USERNAME_OR_PASSWORD, 4).
-define(NOT_AUTHORIZED, 5).

%%
%% Record definitions of MQTT Packets.
%%

-record(mqtt_will, {
        retain :: boolean(),
        qos :: integer(),
        topic :: binary(),
        message :: binary()
}).

-record(mqtt_connect, {
        protocol_name :: binary(),
        protocol_version :: integer(),

        client_id :: binary(),

        username :: undefined | binary(),
        password :: undefined | binary(),

        will :: undefined | #mqtt_will{},

        clean_session :: boolean(),

        keep_alive :: pos_integer()
}).

-record(mqtt_connack, {
        session_present=false :: boolean(),
        connect_return_code :: integer()
}).

-record(mqtt_publish, {
        dup :: boolean(),
        qos :: 0 | 1 | 2,
        retain :: boolean(),

        topic_name :: binary(),

        packet_identifier :: undefined | binary(),
        payload :: binary()
}).

-record(mqtt_puback, {
        packet_identifier :: binary(),
        return_codes :: [0 | 1 | 2 | 16#80]
}).

-record(mqtt_pubrec, {
        packet_identifier :: binary()
}).

-record(mqtt_pubrel, {
        packet_identifier :: binary()
}).

-record(mqtt_pubcomp, {
        packet_identifier :: binary()
}).

-record(mqtt_subscribe, {
        packet_identifier :: binary(),
        topics :: [{binary(), 0 | 1 | 2}]
}).

-record(mqtt_suback, {
        packet_identifier :: binary(),
        return_codes :: [ 0 | 1 | 2 | 16#80 ]
}).

-record(mqtt_unsubscribe, {
        packet_identifier :: binary(),
        topics :: [binary()]
}).

-record(mqtt_unsuback, {
        packet_identifier :: binary()
}).

-record(mqtt_pingreq, {}).
-record(mqtt_pingresp, {}).
-record(mqtt_disconnect, {}).  

