%% @author Maas-Maarten <mmzeeman@xs4all.nl>
%% @copyright 2014 Maas-Maarten Zeeman

%% @doc Notifier, can be used to extend the behaviour of the broker

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

-module(mmqtt_notifier).

-export([start_link/0]).

-export([observe/2, observe/3, notify/2, first/2]).

start_link() ->
    notifier:start_link(?MODULE).

observe(Name, Observer) ->
    notifier:observe(?MODULE, Name, Observer).

observe(Name, Observer, Priority) ->
    notifier:observe(?MODULE, Name, Observer, Priority).

notify(Msg, Args) ->
    notifier:notify(?MODULE, Msg, Args).

first(Msg, Args) ->
    notifier:first(?MODULE, Msg, Args).

