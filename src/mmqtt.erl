%% @author Maas-Maarten <mmzeeman@xs4all.nl>
%% @copyright 2014 Maas-Maarten Zeeman

%% @doc: mmqtt acceptor manager
%%
%% This gen_server owns the listen socket and manages the processes
%% accepting on that socket. When a process waiting for accept gets a
%% request, it notifies this gen_server so we can start up another
%% acceptor.
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

-module(mmqtt).
-behaviour(gen_server).
-include_lib("include/mmqtt.hrl").

%% API
-export([start_link/0,
         start_link/1,
         stop/1,
         get_acceptors/1,
         get_open_connections/1,
         get_open_connections/2,
         set_callback/3
        ]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-type callback() :: {module(), atom()}.

-record(state, {socket :: mmqtt_tcp:socket(),
                acceptors :: [pid()],
                open_connections :: non_neg_integer(),
                options :: [{_, _}],
                callback :: callback()
}).


-type event() :: mmqtt_startup | mmqtt_reconfigure |
    connect_timeout | connect_throw | connect_errori | connect_exit |
    connection_closed | connection_error |
    protocol_error | packet_parse_error |
    in_packet | in_message |
    packet_throw | packet_error | packet_exit |
    info_throw | info_error | info_exit.

-export_type([event/0]).

%%%===================================================================
%%% API
%%%===================================================================

start_link() -> 
    start_link(?EXAMPLE_CONFIG).

start_link(Opts) ->
    valid_callback(required_opt(callback, Opts))
        orelse throw(invalid_callback),

    case proplists:get_value(name, Opts) of
        undefined ->
            gen_server:start_link(?MODULE, [Opts], []);
        Name ->
            gen_server:start_link(Name, ?MODULE, [Opts], [])
    end.

get_acceptors(S) ->
    gen_server:call(S, get_acceptors).

get_open_connections(S) ->
    get_open_connections(S, 5000).

get_open_connections(S, Timeout) ->
    gen_server:call(S, get_open_connections, Timeout).

set_callback(S, Callback, CallbackArgs) ->
    valid_callback(Callback) orelse throw(invalid_callback),
    gen_server:call(S, {set_callback, Callback, CallbackArgs}).

stop(S) ->
    gen_server:call(S, stop).


%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([Opts]) ->
    io:fwrite(standard_error, "Opts: ~p~n", [Opts]),
    %% Use the exit signal from the acceptor processes to know when
    %% they exit
    process_flag(trap_exit, true),

    Callback       = required_opt(callback, Opts),
    CallbackArgs   = proplists:get_value(callback_args, Opts),
    IPAddress      = proplists:get_value(ip, Opts, {0,0,0,0}),
    Port           = proplists:get_value(port, Opts, 1883),
    MinAcceptors   = proplists:get_value(min_acceptors, Opts, 50),

    UseSSL         = proplists:get_value(ssl, Opts, false),
    KeyFile        = proplists:get_value(keyfile, Opts),
    CertFile       = proplists:get_value(certfile, Opts),
    SockType       = case UseSSL of true -> ssl; false -> plain end,
    SSLSockOpts    = case UseSSL of
                         true -> [{keyfile, KeyFile},
                                  {certfile, CertFile}];
                         false -> [] end,

    AcceptTimeout  = proplists:get_value(accept_timeout, Opts, 10000),
    ConnectTimeout = proplists:get_value(connect_timeout, Opts, 60000),

    Options = [{accept_timeout, AcceptTimeout},
               {connect_timeout, ConnectTimeout}],

    %% Notify the handler that we are about to start accepting
    %% requests, so it can create necessary supporting processes, ETS
    %% tables, etc.
    ok = Callback:handle_event(mmqtt_startup, [], CallbackArgs),

    {ok, Socket} = mmqtt_tcp:listen(SockType, Port, [binary,
                                                    {ip, IPAddress},
                                                    {reuseaddr, true},
                                                    {backlog, 32768},
                                                    {packet, raw},
                                                    {nodelay, true},
                                                    {active, false}
                                                    | SSLSockOpts
                                                   ]),
    Acceptors = [mmqtt_protocol:start_link(self(), Socket, Options, 
            {Callback, CallbackArgs}) || _ <- lists:seq(1, MinAcceptors)],

    {ok, #state{socket = Socket,
                acceptors = Acceptors,
                open_connections = 0,
                options = Options,
                callback = {Callback, CallbackArgs}}}.


handle_call(get_acceptors, _From, State) ->
    {reply, {ok, State#state.acceptors}, State};

handle_call(get_open_connections, _From, State) ->
    {reply, {ok, State#state.open_connections}, State};

handle_call({set_callback, Callback, CallbackArgs}, _From, State) ->
    ok = Callback:handle_event(mmqtt_reconfigure, [], CallbackArgs),
    {reply, ok, State#state{callback = {Callback, CallbackArgs}}};

handle_call(stop, _From, State) ->
    {stop, normal, ok, State}.

handle_cast(accepted, State) ->
    {noreply, start_add_acceptor(State)};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'EXIT', _Pid, {error, emfile}}, State) ->
    error_logger:error_msg("No more file descriptors, shutting down~n"),
    {stop, emfile, State};

handle_info({'EXIT', Pid, normal}, State) ->
    {noreply, remove_acceptor(State, Pid)};

handle_info({'EXIT', Pid, Reason}, State) ->
    error_logger:error_msg("MMQTT acceptor (pid ~p) unexpectedly "
                           "crashed:~n~p~n", [Pid, Reason]),
    {noreply, remove_acceptor(State, Pid)}.


terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

remove_acceptor(State, Pid) ->
    State#state{acceptors = lists:delete(Pid, State#state.acceptors),
                open_connections = State#state.open_connections - 1}.

start_add_acceptor(State) ->
    Pid = mmqtt_protocol:start_link(self(), State#state.socket,
        State#state.options, State#state.callback),
    State#state{acceptors = [Pid | State#state.acceptors],
                open_connections = State#state.open_connections + 1}.

required_opt(Name, Opts) ->
    case proplists:get_value(Name, Opts) of
        undefined ->
            throw(badarg);
        Value ->
            Value
    end.

valid_callback(Mod) ->
    Exports = Mod:module_info(exports),
    lists:member({handle_event, 3}, Exports).
