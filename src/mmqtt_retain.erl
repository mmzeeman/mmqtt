
-module(mmqtt_retain).

-include("mmqtt.hrl").
-include("mmqtt_packet.hrl").

-behaviour(gen_server).

-export([
    start_link/0,

    delete/1,
    insert/1
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(RETAIN_TABLE, mmqtt_retain).

-record(retained, {
        topic :: binary(),
        message :: mmqtt_packet:mqtt_publish(),
        created=os:timestamp()
    }).

%%
%% Api
%%

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).


% @doc Delete a retained message.
%
delete(#mqtt_publish{topic_name=Topic}) ->
    delete(Topic);
delete(Topic) ->
    ets:delete_object(?RETAIN_TABLE, Topic).

insert(#mqtt_publish{topic_name=Topic}=Message) ->
    ets:insert(?RETAIN_TABLE, #retained{topic=Topic, message=Message}).

%%
%% Gen-server callbacks
%%

init([]) ->
    %% Create the retained table.
    ets:new(?RETAIN_TABLE, [public, named_table, 
            {read_concurrency, true}, {write_concurrency, true}, {keypos, 2}]),

    %% TODO: delete entries that are too old.
    %% TODO: qos1 and qos2 messages need to survive a restart.

    {ok, []}.

handle_call(stop, _From, State) ->
    {stop, normal, ok, State};

handle_call(Req, _From, State) ->
    {stop, {badreq,Req}, State}.

handle_cast(Msg, State) ->
    {stop, {badmsg, Msg}, State}.

handle_info(Info, State) ->
    lager:warning("Unexpected message: ~p", [Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

