%% @author Maas-Maarten <mmzeeman@xs4all.nl>
%% @copyright 2014 Maas-Maarten Zeeman

%% @doc Middleware logic

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

-module(mmqtt_middleware).
-behaviour(mmqtt_handler).
-export([connect/3, handle_event/3]).

-include("include/mmqtt_packet.hrl").

%% Connect
%%
connect(Connect, Socket, Config) ->
    Mods = mods(Config),
    process_connect(Connect, Socket, Mods).

process_connect(_Connect, _Socket, []) ->
    %% No middleware wanted to handle this connection
    {stop, normal, #mqtt_connack{connect_return_code=?UNACCEPTABLE_PROTOCOL_VERSION}};
process_connect(Connect, Socket, [{Mod, Args}|Mods]) ->
    case erlang:function_exported(Mod, connect, 3) of
        true ->
            case Mod:connect(Connect, Socket, Args) of
                ignore ->
                    process_connect(Connect, Socket, Mods);
                Response -> 
                    {Response, Mod}
            end;
        false ->
            process_connect(Connect, Socket, Mods)
    end.

%% Events
%%
handle_event(mmqtt_startup, Args, Config) ->
    lists:foreach(fun code:ensure_loaded/1, 
        lists:map(fun ({M, _}) -> M end, mods(Config))),
    forward_event(mmqtt_startup, Args, mods(Config));
handle_event(Event, Args, Config) ->
    forward_event(Event, Args, lists:reverse(mods(Config))).

forward_event(Event, Args, Mods) ->
    lists:foreach(
        fun ({M, ExtraArgs}) ->
                case erlang:function_exported(M, handle_event, 3) of
                    true ->
                        M:handle_event(Event, Args, ExtraArgs);
                    false ->
                        ok
                end
        end, Mods),
    ok.

%%
%% Helpers
%%

mods(Config) -> 
    proplists:get_value(mods, Config).
