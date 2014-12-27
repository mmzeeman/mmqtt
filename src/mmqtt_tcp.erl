%% @author Maas-Maarten <mmzeeman@xs4all.nl>
%% @copyright 2014 Maas-Maarten Zeeman

%% @doc: Tiny wrapper for plain and SSL sockets. Based on mochiweb_socket.erl

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




-module(mmqtt_tcp).
-export([
    listen/3, 
    accept/2, 
    recv/3, 
    send/2, 
    close/1, 
    setopts/2, 
    sendfile/5, 
    peername/1,
    messages/1
]).

-export_type([socket/0]).

-type socket() :: {plain, inet:socket()} | {ssl, ssl:sslsocket()}.

listen(plain, Port, Opts) ->
    case gen_tcp:listen(Port, Opts) of
        {ok, Socket} ->
            {ok, {plain, Socket}};
        {error, Reason} ->
            {error, Reason}
    end;

listen(ssl, Port, Opts) ->
    case ssl:listen(Port, Opts) of
        {ok, Socket} ->
            {ok, {ssl, Socket}};
        {error, Reason} ->
            {error, Reason}
    end.


accept({plain, Socket}, Timeout) ->
    case gen_tcp:accept(Socket, Timeout) of
        {ok, S} ->
            {ok, {plain, S}};
        {error, Reason} ->
            {error, Reason}
    end;
accept({ssl, Socket}, Timeout) ->
    case ssl:transport_accept(Socket, Timeout) of
        {ok, S} ->
            case ssl:ssl_accept(S, Timeout) of
                ok ->
                    {ok, {ssl, S}};
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.


recv({plain, Socket}, Size, Timeout) ->
    gen_tcp:recv(Socket, Size, Timeout);
recv({ssl, Socket}, Size, Timeout) ->
    ssl:recv(Socket, Size, Timeout).

send({plain, Socket}, Data) ->
    gen_tcp:send(Socket, Data);
send({ssl, Socket}, Data) ->
    ssl:send(Socket, Data).

close({plain, Socket}) ->
    gen_tcp:close(Socket);
close({ssl, Socket}) ->
    ssl:close(Socket).

setopts({plain, Socket}, Opts) ->
    inet:setopts(Socket, Opts);
setopts({ssl, Socket}, Opts) ->
    ssl:setopts(Socket, Opts).

sendfile(Fd, {plain, Socket}, Offset, Length, Opts) ->
    file:sendfile(Fd, Socket, Offset, Length, Opts);
sendfile(_Fd, {ssl, _}, _Offset, _Length, _Opts) ->
    throw(ssl_sendfile_not_supported).

peername({plain, Socket}) ->
    inet:peername(Socket);
peername({ssl, Socket}) ->
    ssl:peername(Socket).

messages({plain, _Socket}) ->
    {tcp, tcp_passive, tcp_closed, tcp_error};
messages({ssl, _Socket}) ->
    % Note: ssl_passive is never returned in reality
    {ssl, ssl_passive, ssl_closed, ssl_error}.
    
