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
     log_packet_offline/1,
     post_result/1]).

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

        ToVal = case xmpp:get_subtag(Msg, #addresses{}) of
          #addresses{list = Addresses} ->
            Jids = lists:foldl(
                  fun(Address, St) ->
                          case Address#address.jid of
                              #jid{} = JID ->
                                  LJID = jid:encode(JID),
                                  ?INFO_MSG("LJID ~s",[LJID]),
                            lists:append(St, [erlang:binary_to_list(LJID)]);
                              undefined ->
                                  St
                          end
                  end, [], Addresses),
            string:join(Jids, ",");
          false ->
            erlang:binary_to_list(jid:encode(To))
        end,

        %?INFO_MSG("AddressesJids: ~s", [ToVal]),

        if Direction1 == outgoing ->
            #jid{lserver = LServer} = From;
          true ->
            #jid{lserver = LServer} = To
        end,
        Url = gen_mod:get_module_opt(LServer, ?MODULE, url, fun(S) -> iolist_to_binary(S) end, false),
        % url params
        DateVal = lists:flatten(Date),
        DirectionVal = lists:flatten(io_lib:format("~s", [ Direction1])), 
        TypeVal = lists:flatten(io_lib:format("~s", [ Type1])),
        IdVal = lists:flatten(io_lib:format("~s", [ binary_to_list(Id)])),
        FromVal = lists:flatten(io_lib:format("~s", [ jid:encode(From)])),
        %ToVal = lists:flatten(io_lib:format("~s", [ jid:encode(To)])),
        MessageVal = lists:flatten(io_lib:format("~s", [ xmpp:get_text(Body)])),
        % post data
        PostData = string:join([
            "date=", http_uri:encode(DateVal), 
            "&direction=", http_uri:encode(DirectionVal), 
            "&type=", http_uri:encode(TypeVal),
            "&id=", http_uri:encode(IdVal),
            "&from=", http_uri:encode(FromVal),
            "&to=", http_uri:encode(ToVal),
            "&message=", http_uri:encode(MessageVal)
          ], ""
        ),
        if Type1 == chat ->
            {ok, _ReqId} = httpc:request(post,
               {Url, [], "application/x-www-form-urlencoded", PostData},
               [],
               [ {sync, false},
                 {receiver, {?MODULE, post_result, []}}
                 | [] ]),
            ?INFO_MSG("request: Url ~s Date ~s Direction ~s Type ~s Message ~s ID ~s From ~s To ~s", 
              [Url, DateVal, DirectionVal, TypeVal, MessageVal, IdVal, FromVal, ToVal]);
          true ->
            ?INFO_MSG("log: Date ~s Direction ~s Type ~s Message ~s ID ~s From ~s To ~s", 
              [DateVal, DirectionVal, TypeVal, MessageVal, IdVal, FromVal, ToVal])
        end;
    false ->
        ok
    end.

post_result({_ReqId, {error, Reason}}) ->
    report_error([ {error, Reason } ]);
post_result({_ReqId, Result}) ->
    {StatusLine, Headers, Body} = Result,
    {_HttpVersion, StatusCode, ReasonPhrase} = StatusLine,
    if StatusCode < 200;
       StatusCode > 299 ->
            ok = report_error([ {status_code,   StatusCode},
                                {reason_phrase, ReasonPhrase},
                                {headers,       Headers},
                                {body,          Body} ]),
            ok;
       true ->
            ok
    end.

report_error(ReportArgs) ->
    ok = error_logger:error_report([ mod_message_http_post_cannot_post | ReportArgs ]).

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

-spec format_date(calendar:datetime()) -> io_lib:chars().
format_date({{Year, Month, Day}, {Hour, Minute, Second}}) ->
    Format = "~B-~2..0B-~2..0B ~2..0B:~2..0B:~2..0B",
    io_lib:format(Format, [Year, Month, Day, Hour, Minute, Second]).
