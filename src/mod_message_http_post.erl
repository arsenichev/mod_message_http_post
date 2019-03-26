%%%----------------------------------------------------------------------
%%% File    : mod_message_http_post.erl
%%% Author  : Sergey Arsenichev <s@arsenichev.ru>
%%% Purpose : Ejabberd module log messages to remote http server (via webhook)
%%% Created : 13 March 2019 by Sergey Arsenichev <s@arsenichev.ru>
%%%----------------------------------------------------------------------

-module(mod_message_http_post).
-author('s@arsenichev.ru').

-behaviour(gen_mod).

%% gen_mod callbacks.
-export([start/2,
     stop/1,
     mod_opt_type/1,
     mod_options/1,
     depends/2]).

%% ejabberd_hooks callbacks.
-export([log_packet_send/1,
     log_packet_receive/1,
     log_packet_offline/1]).

-include("xmpp.hrl").
-include("logger.hrl").

-type direction() :: incoming | outgoing | offline.
-type c2s_state() :: ejabberd_c2s:state().
-type c2s_hook_acc() :: {stanza() | drop, c2s_state()}.

%% -------------------------------------------------------------------
%% gen_mod callbacks.
%% -------------------------------------------------------------------
-spec start(binary(), gen_mod:opts()) -> {ok, _} | {ok, _, _} | {error, _}.
start(Host, _Opts) ->
    ejabberd_hooks:add(user_send_packet, Host, ?MODULE,
               log_packet_send, 42),
    ejabberd_hooks:add(user_receive_packet, Host, ?MODULE,
               log_packet_receive, 42),
    ejabberd_hooks:add(offline_message_hook, Host, ?MODULE,
               log_packet_offline, 42),
    ok.

-spec stop(binary()) -> ok.
stop(Host) ->
    ejabberd_hooks:delete(user_send_packet, Host, ?MODULE,
              log_packet_send, 42),
    ejabberd_hooks:delete(user_receive_packet, Host, ?MODULE,
              log_packet_receive, 42),
    ejabberd_hooks:delete(offline_message_hook, Host, ?MODULE,
              log_packet_offline, 42),
    ok.

-spec mod_opt_type(atom()) -> fun((term()) -> term()).
mod_opt_type(url) ->
    fun(Val) when is_binary(Val) -> binary_to_list(Val);
       (Val) -> Val
    end.

-spec mod_options(binary()) -> [{atom(), any()}].
mod_options(_Host) ->
    [{url, false}].


-spec depends(binary(), gen_mod:opts()) -> [{module(), hard | soft}].
depends(_Host, _Opts) ->
    [].


%% -------------------------------------------------------------------
%% ejabberd_hooks callbacks.
%% -------------------------------------------------------------------
-spec log_packet_send(c2s_hook_acc()) -> c2s_hook_acc().
log_packet_send({#message{} = Msg, _C2SState} = Acc) ->
    log_packet(outgoing, Msg),
    Acc;
log_packet_send({_Stanza, _C2SState} = Acc) ->
    Acc.

-spec log_packet_receive(c2s_hook_acc()) -> c2s_hook_acc().
log_packet_receive({#message{} = Msg, _C2SState} = Acc) ->
    log_packet(incoming, Msg),
    Acc;
log_packet_receive({_Stanza, _C2SState} = Acc) ->
    Acc.

-spec log_packet_offline({any(), message()}) -> {any(), message()}.
log_packet_offline({_Action, Msg} = Acc) ->
    log_packet(offline, Msg),
    Acc.


%% -------------------------------------------------------------------
%% Internal functions.
%% -------------------------------------------------------------------
-spec log_packet(direction(), message()) -> any().
log_packet(Direction, #message{type = Type, body = Body, id = Id, from = From, to = To} = Msg) ->
    case should_log(Msg) of
    true ->
        {Type1, Direction1} = case is_carbon(Msg) of
                      {true, Direction0} ->
                      {carbon, Direction0};
                      false ->
                      {Type, Direction}
                  end,
        % Proc = gen_mod:get_module_proc(global, ?MODULE),
        % gen_server:cast(Proc, {message, Direction1, From, To, Type1, Msg});
        Date = format_date(calendar:local_time()),
        if Direction1 == 'outgoing' ->
            #jid{lserver = LServer} = From;
          true ->
            #jid{lserver = LServer} = To
        end,
        Url = gen_mod:get_module_opt(LServer, ?MODULE, url, fun(S) -> iolist_to_binary(S) end, false),
        ?INFO_MSG("log_packet: Url ~s Date ~s Direction ~s Type ~s Message ~s ID ~s From ~s To ~s", 
          [Url, Date, Direction1, Type1, xmpp:get_text(Body), binary_to_list(Id), jid:encode(From), jid:encode(To)]);
    false ->
        ok
    end.

-spec is_carbon(message()) -> {true, direction()} | false.
is_carbon(#message{meta = #{carbon_copy := true}} = Msg) ->
    case xmpp:has_subtag(Msg, #carbons_sent{}) of
    true ->
        {true, outgoing};
    false ->
        {true, incoming}
    end;
is_carbon(_Msg) ->
    false.

-spec should_log(message()) -> boolean().
should_log(#message{meta = #{carbon_copy := true}} = Msg) ->
    should_log(misc:unwrap_carbon(Msg));
should_log(#message{type = error}) ->
    false;
should_log(#message{body = Body, sub_els = SubEls}) ->
    xmpp:get_text(Body) /= <<>>
    orelse lists:any(fun(#xmlel{name = <<"encrypted">>}) -> true;
                (_) -> false
             end, SubEls).

% -spec write_log(io:device(), direction(), jid(), jid(),
%         message_type() | offline | carbon, message()) -> ok.
% write_log(IoDevice, Direction, From, To, Type, Msg) ->
%     Date = format_date(calendar:local_time()),
%     #message{body = Body, id = Id} = Msg,
%     Record = io_lib:format("~s [~s, ~s, ~s, ~p] ~s -> ~s~n",
%                [Date, Direction, Type, xmpp:get_text(Body), Id,
%                 jid:encode(From), jid:encode(To)]),
%     ok = file:write(IoDevice, [Record]).

-spec format_date(calendar:datetime()) -> io_lib:chars().
format_date({{Year, Month, Day}, {Hour, Minute, Second}}) ->
    Format = "~B-~2..0B-~2..0B ~2..0B:~2..0B:~2..0B",
    io_lib:format(Format, [Year, Month, Day, Hour, Minute, Second]).
