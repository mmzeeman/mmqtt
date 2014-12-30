%%
%% 
%%

-module(mmqtt_auth_anonymous).

-export([init/1, logon/4]).

%% 
init(_Options) ->
    ok.

%% 
logon(_UserName, _Password, _Socket, _Options) ->
    {accepted, []}.

