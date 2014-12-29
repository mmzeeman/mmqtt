%%
%%
%%

-module(mmqtt_basic_auth).

-export([observe/0]).

-include("include/mmqtt.hrl").

-define(PRIO, 9999).

-export([observe_logon/2]).

%%
observe() ->
    mmqtt_notifier:observe(logon, {?MODULE, observe_logon}, ?PRIO).

%% 
observe_logon(#logon{socket=Socket}, Options) ->
    lager:info("options: ~p", [Options]),
    lager:info("info: ~p", [mmqtt_tcp:peername(Socket)]),
    undefined.

