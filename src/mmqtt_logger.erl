%% @author Maas-Maarten <mmzeeman@xs4all.nl>
%% @copyright 2014 Maas-Maarten Zeeman

%% @doc: Simple mmqtt middleware logger.
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

-module(mmqtt_logger).

-include("include/mmqtt.hrl").
-include("include/mmqtt_packet.hrl").

-export([
    handle_event/3
]).

handle_event(Evt, EvtArgs, Args) ->
    lager:info("handle_event: ~p, ~p ~p~n", [Evt, EvtArgs, Args]). 

    
