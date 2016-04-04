%% Copyright (c) 2012-2016 Peter Morgan <peter.james.morgan@gmail.com>
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%% http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

-module(mdns_discovery).
-behaviour(gen_server).

-export([start_link/0]).
-export([stop/0]).

-export([code_change/3]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([init/1]).
-export([terminate/2]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

stop() ->
    gen_server:cast(?MODULE, stop).


init([]) ->
    case mdns_udp:open() of
        {ok, State} ->
            {ok, State};

        {error, Reason} ->
            {stop, Reason}
    end.


handle_call(_, _, State) ->
    {stop, error, State}.


handle_cast(stop, State) ->
    {stop, normal, State}.


handle_info({udp, Socket, _, _, Packet}, State) ->
    inet:setopts(Socket, [{active, once}]),
    {noreply, handle_packet(Packet, State)}.


terminate(_Reason, #{socket := Socket}) ->
    gen_udp:close(Socket).


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


handle_packet(Packet, #{service := Service, domain := Domain} = State) ->
    {ok, Record} = inet_dns:decode(Packet),
    Header = header(Record),
    handle_record(header(Record),
                  record_type(Record),
                  get_value(qr, Header),
                  get_value(opcode, Header),
                  questions(Record),
                  answers(Record),
                  authorities(Record),
                  resources(Record),
                  Service ++ Domain,
                  State).

header(Record) ->
    inet_dns:header(inet_dns:msg(Record, header)).

record_type(Record) ->
    inet_dns:record_type(Record).

questions(Record) ->
    Qs = inet_dns:msg(Record, qdlist),
    [maps:from_list(inet_dns:dns_query(Q)) || Q <- Qs].

answers(Record) ->
    rr(inet_dns:msg(Record, anlist)).

authorities(Record) ->
    rr(inet_dns:msg(Record, nslist)).

resources(Record) ->
    rr(inet_dns:msg(Record, arlist)).

rr(Resources) ->
    [maps:from_list(inet_dns:rr(Resource)) || Resource <- Resources].


handle_record(_,
              msg,
              false,
              query,
              [#{domain := ServiceDomain, type := ptr, class := in}],
              [],
              [],
              [],
              ServiceDomain,
              State) ->
    mdns_advertiser:multicast(),
    State;

handle_record(_,
              msg,
              false,
              query,
              [#{domain := ServiceDomain, type := ptr, class := in}],
              [#{data := Data}],
              [],
              [],
              ServiceDomain,
              State) ->
    case lists:member(Data, local_instances(State)) of
        true ->
            mdns_advertiser:multicast(),
            State;
        _ ->
            State
    end;

handle_record(_,
              msg,
              true,
              query,
              [],
              Answers,
              [],
              Resources,
              ServiceDomain,
              State) ->
    handle_advertisement(Answers, Resources, ServiceDomain, State);

handle_record(_, msg, false, query, _, _, _, _, _, State) ->
    State.


local_instances(State) ->
    {ok, Names} = net_adm:names(),
    {ok, Hostname} = inet:gethostname(),
    [instance(Node, Hostname, State) || {Node, _} <- Names].

instance(Node, Hostname, #{service := Service, domain := Domain}) ->
    Node ++ "@" ++ Hostname ++ "." ++ Service ++ Domain.

handle_advertisement([#{domain := ServiceDomain,
                        type := ptr,
                        class := in,
                        ttl := 0,
                        data := Data} | Answers],
                     Resources,
                     ServiceDomain,
                     State) ->
    Node = node_and_hostname(
             [{Type,
               RD} || #{domain := RDomain,
                          type := Type,
                          data := RD} <- Resources, RDomain == Data]),
    mdns:notify(advertisement, #{node => Node, ttl => 0}),
    handle_advertisement(Answers, Resources, ServiceDomain, State);

handle_advertisement([#{domain := ServiceDomain,
                        type := ptr,
                        class := in,
                        ttl := TTL,
                        data := Data} | Answers],
                     Resources,
                     ServiceDomain,
                     State) ->
    case node_and_hostname(
           [{Type,
             RD} || #{domain := RDomain,
                      type := Type,
                      data := RD} <- Resources, RDomain == Data]) of
        Node when Node /= node() ->
            mdns:notify(advertisement, #{node => Node, ttl => TTL}),
            mdns_advertiser:multicast();

        _ ->
            nop
    end,
    handle_advertisement(Answers, Resources, ServiceDomain, State);

handle_advertisement([_ | Answers], Resources, ServiceDomain, State) ->
    handle_advertisement(Answers, Resources, ServiceDomain, State);

handle_advertisement([], _, _, State) ->
    State.


node_and_hostname(P) ->
    node_name(get_value(txt, P)) ++ "@" ++ host_name(get_value(txt, P)).

node_name([[$n, $o, $d, $e, $= | Name] | _]) ->
    Name;
node_name([_ | T]) ->
    node_name(T).

host_name([[$h, $o, $s, $t, $n, $a, $m, $e, $= | Hostname] | _]) ->
    Hostname;
host_name([_ | T]) ->
    host_name(T).

get_value(Key, List) ->
    proplists:get_value(Key, List).
