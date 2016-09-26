%% @author Maas-Maarten <mmzeeman@xs4all.nl>
%% @copyright 2016 Maas-Maarten Zeeman

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

-export([
    start_link/0,
    start_link/1,

    start_clear/3,
    start_clear/4
]).

-include_lib("include/mmqtt.hrl").


start_link() ->
    start_link(?EXAMPLE_CONFIG).

start_link(Options) ->
    valid_callback(required_opt(callback, Options)) orelse throw(invalid_callback),

    %%
    DefaultTransOpts = [{port, 1883}, {max_connections, 100}],

    case proplists:get_value(name, Options) of
        undefined ->
            start_clear(?MODULE, DefaultTransOpts, Options);
        Name ->
            start_clear(Name, DefaultTransOpts, Options)
    end.


-spec start_clear(ranch:ref(), ranch_tcp:opts(), mmqtt_protocol:opts()) -> {ok, pid()} | {error, any()}.
start_clear(Ref, TransOpts, ProtoOpts)  ->
    start_clear(Ref, 100, TransOpts, ProtoOpts).

-spec start_clear(ranch:ref(), non_neg_integer(), ranch_tcp:opts(), mmqtt_protocol:opts()) -> {ok, pid()} | {error, any()}.
start_clear(Ref, NbAcceptors, TransOpts, ProtoOpts) when is_integer(NbAcceptors), NbAcceptors > 0 ->
    mmqtt_protocol:startup(ProtoOpts),
    ranch:start_listener(Ref, NbAcceptors, ranch_tcp, TransOpts, mmqtt_protocol, ProtoOpts).

%%
%% Helpers
%%

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

