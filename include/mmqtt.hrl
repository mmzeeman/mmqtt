
-define(QOS_0, 0).
-define(QOS_1, 1).
-define(QOS_2, 2).

-record(mqtt_msg, {
        retain,
        qos,
        topic,
        dup,
        message_id,
        payload,
        encoder}).
   

-define(EXAMPLE_CONFIG, [
        {callback, mmqtt_middleware},
        {callback_args, [
                {mods, [ 
                        {mmqtt_connection, [
                                {auth, {mmqtt_auth_anonymous, []}}
                            ]},
                        {mmqtt_logger, [{logger, true}]}
                    ]}
            ]}
    ]).

%%
%% Notifications
%%

%% Check if action is allowed. 

%% A client subscribed to a topic
-record(client_subscribe, {
    topic :: binary(),
    qos :: 0 | 1 | 2
}).

%% A client un-subscribed 
-record(client_unsubscribe, {
    topic :: binary(),
    qos :: 0 | 1 | 2
}).

