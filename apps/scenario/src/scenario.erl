%%
%%   Copyright 2016 Zalando SE
%%
%%   Licensed under the Apache License, Version 2.0 (the "License");
%%   you may not use this file except in compliance with the License.
%%   You may obtain a copy of the License at
%%
%%       http://www.apache.org/licenses/LICENSE-2.0
%%
%%   Unless required by applicable law or agreed to in writing, software
%%   distributed under the License is distributed on an "AS IS" BASIS,
%%   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%   See the License for the specific language governing permissions and
%%   limitations under the License.
%%
%% @doc
%%   the library implements definition, and compilation of typhoon load scripts.
%%   see docs/scenario.md for detailed specification of dsl
-module(scenario).
-include("scenario.hrl").

-export([
   compile/1,
   n/1,
   t/1,
   eval/1,
   accept/2
]).
-export([
   uid/0,
   int/1,
   pareto/2,
   ascii/1,
   text/1,
   lens/2
]).

%%
-type scenario() :: #{
   n   => integer(),
   t   => integer(),
   seq => datum:q()
}.

%%
%% compile scenario
-spec compile(_) -> scenario().

compile(Spec) ->
   ?CONTEXT = lens:get(lens:pair(<<"@context">>), Spec),
   N   = lens:get(lens:pair(<<"n">>, ?CONFIG_N), Spec),
   T   = tempus:t(m, lens:get(lens:pair(<<"t">>, ?CONFIG_T), Spec)),
   Heap= compile_heap(lens:get(lens:pair(<<"heap">>, []), Spec)),
   Seq = deq:new([compile_req(Spec, Req) 
      || Req <- lens:get(lens:pair(<<"seq">>), Spec)]),
   #{n => N, t => T, heap => Heap, seq => Seq}.

%%
%% number of processes
-spec n(scenario()) -> integer().

n(#{n := N}) ->
   N.

%%
%% time to execute scenario
-spec t(scenario()) -> tempus:t().

t(#{t := T}) ->
   T.

%%
%% evaluates request to list of communication primitives
-spec eval(fun((_) -> ok), scenario()) -> {binary(), [_], scenario()}.

eval(#{seq :=  {}} = Scenario) ->
   % evaluate empty scenario
   {#{}, Scenario};

eval(#{seq := Seq} = Scenario) ->
   eval(deq:head(Seq), 
      Scenario#{seq => deq:enq(deq:head(Seq), deq:tail(Seq))}
   ).

eval(#{id := Urn, thinktime := T}, Scenario) ->
   {#{type => thinktime, urn => Urn, t => scalar:i(T(?CONFIG_SCRIPT_ALLOWED))}, Scenario};

eval(#{id := Urn} = Unit, #{heap := Heap} = Scenario) ->
   List = lists:flatten([
      http_head(Heap, Unit), http_payload(Heap, Unit), http_eof(Heap, Unit)
   ]),
   {#{type => protocol,  urn => Urn, packet => List}, Scenario}.


%%
%% accept result to impact on heap state
-spec accept(binary(), scenario()) -> scenario().

accept(Payload, #{seq := Seq, heap := Heap} = Scenario) ->
   case deq:last(Seq) of
      #{lens := {Id, Lens}} ->
         case lens:get(Lens, jsx:decode(Payload)) of
            [] ->
               Scenario;
            Value ->
               Key = scalar:s(Id),
               Scenario#{heap => Heap#{Key => Value}}
         end;
      _ ->
         Scenario
   end.

%%%----------------------------------------------------------------------------   
%%%
%%% script interface
%%%
%%%----------------------------------------------------------------------------   

%%
%% generate globally unique sequential (k-order) identity
-spec uid() -> binary().

uid() ->
   bits:btoh( uid:encode(uid:g()) ).

%%
%% generate uniformly distributed integer
-spec int(integer()) -> binary().

int(N) ->
   scalar:s(random:uniform(N)).

%%
%% generate random integer using Pareto distribution
-spec pareto(float(), integer()) -> binary().

pareto(A, N) ->
   scalar:s(pdf:pareto(A, N)).

%%
%% generate random ASCII payload of given length, 
%% characters are uniformly distributed
-spec ascii(integer()) -> binary().

ascii(N) ->
   scalar:s(
      stream:list(
         stream:take(N, ascii())
      )
   ).

ascii() ->
   stream:unfold(
      fun(Seed) ->
         Head = case random:uniform(3) of
            1 -> $0 + (random:uniform(10) - 1);
            2 -> $a + (random:uniform($z - $a) - 1);
            3 -> $A + (random:uniform($Z - $A) - 1)
         end,
         {Head, Seed}
      end,
      0
   ).

%%
%% generate random text using Pareto distributions
-spec text(integer()) -> binary().

text(N) ->
   scalar:s(
      stream:list(
         stream:take(N, text())
      )
   ).

text() ->
   stream:unfold(
      fun(Seed) ->
         Head = case pdf:pareto(0.4, 27) of
            1 -> $ ;
            X -> $a + X - 1
         end,
         {Head, Seed}
      end,
      0
   ).

%%
%% lens focuses on variable at heap 
lens(Focus, Context) ->
   Lens = lens:c([lens:map(heap) | focus(Focus)]),
   scalar:s( lens:get(Lens, Context) ).

focus([uniform | T]) ->
   [lens_uniform() | T];

focus([H | T])
 when is_atom(H) ->
   [lens:map(scalar:s(H)) | focus(T)];

focus([]) ->
   [].

%%
%% focus on random element from set
lens_uniform() ->
   fun(Fun, List) ->
      lens:fmap(fun(_) -> List end, Fun(lens_uniform(List)))
   end.

lens_uniform(List) ->
   lists:nth(random:uniform(length(List)), List).


%%%----------------------------------------------------------------------------   
%%%
%%% private
%%%
%%%----------------------------------------------------------------------------   

%%
%% compile request
compile_req(Spec, Unit) ->
   Id = uri:new( lens:get(lens:pair(<<"@id">>), Unit) ),
   case lens:get(lens:pair(<<"@type">>, <<"http">>), Unit) of
      <<"http">>  ->
         compile_return(Spec, Unit,
            compile_payload(Spec, Unit,
               compile_uri(Spec, Unit, 
                  compile_header(Spec, Unit, 
                     compile_method(Spec, Unit, #{id => Id})
                  )
               )
            )
         );
      <<"thinktime">> = _Type ->
         compile_thinktime(Spec, Unit, #{id => Id})
   end.
   
%%
compile_uri(Spec, Unit, Req) ->
   Base = lens:get(lens:pair(<<"url">>, <<>>), Spec),
   Path = lens:get(lens:pair(<<"url">>), Unit),
   Fun  = swirl:f(<<Base/binary, Path/binary>>),
   Req#{uri => Fun(undefined)}.

%%
compile_payload(_Spec, Unit, Req) ->
   case lens:get(lens:pair(<<"payload">>, undefined), Unit) of
      undefined ->
         Req;
      Data ->
         Fun = swirl:f(Data),
         Req#{payload => Fun(undefined)}
   end.

%%
compile_header(Spec, Unit, Req) ->
   Base = lens:get(lens:pair(<<"header">>, []), Spec),
   Head = lens:get(lens:pair(<<"header">>, []), Unit),
   Http = lists:map(
      fun({Key, Val}) ->
         Fun = swirl:f(Val),
         {Key, Fun(undefined)}
      end,
      Base ++ Head
   ),
   Req#{header => Http}.

%%
compile_method(_Spec, Unit, Req) ->
   Mthd = lens:get(lens:pair(<<"method">>, []), Unit),
   Req#{method => scalar:a(Mthd)}.

%%
compile_thinktime(_Spec, Unit, Req) ->
   case lens:get(lens:pair(<<"t">>, undefined), Unit) of
      undefined ->
         Req;
      T when is_integer(T) ->
         Req#{thinktime => fun(_) -> T end};
      T when is_binary(T) ->
         Fun = swirl:f(T),
         Req#{thinktime => Fun(undefined)}
   end.

%%
compile_return(_Spec, Unit, Req) ->
   case lens:get(lens:pair(<<"return">>, undefined), Unit) of
      [{Id, Focus}] ->
         Req#{lens => {Id, lens:c([lens:pair(X, []) || X <- Focus])}};  
      
      %% lens in not defined or wrong syntax
      _ ->
         Req
   end.

%% compile data sets into format processable by scenario
compile_heap(List) ->
   maps:from_list(List).

%%
%%
http_head(Heap, #{method := Mthd, uri := Uri, header := Head}) ->
   [
      {
         Mthd, 
         uri:new(scalar:s( Uri( context(Heap) ) )), 
         %% @todo: header files are forced to atom due to htstream issue.
         [{scalar:atom(Key), Val( context(Heap) ) } || {Key, Val} <- Head]
      }
   ].

%%
http_payload(Heap, #{payload := Payload}) ->
   [
      scalar:s( Payload( context(Heap) ) )
   ];
http_payload(_Heap, _Req) ->
   [].

%%
http_eof(_Heap, _Req) ->
   [eof].


%% build context for evaluator
context(Heap) ->
   maps:put(heap, Heap, ?CONFIG_SCRIPT_ALLOWED).

