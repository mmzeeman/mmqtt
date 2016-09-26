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


-module(mmqtt_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    ok = ensure_started([syntax_tools, compiler, goldrush, lager]),
    ok = ensure_started([gproc]),
    ok = ensure_started([ranch]),
    ok = ensure_started([router]),

    %% Start our application supervisor
    mmqtt_sup:start_link().

stop(_State) ->
    ok.


%%
%% Helpers
%%

ensure_started([]) -> ok;
ensure_started([App|Apps]) ->
    case application:start(App) of
        ok -> ok;
        {error, {already_started, App}} -> ok
    end,
    ensure_started(Apps).



