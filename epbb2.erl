-module(epbb2).
-author('baryluk@smp.if.uj.edu.pl').

% Copyright (c) 2011, Witold Baryluk
% All rights reserved.
% Licensed under BSD license, see LICENSE for details.

% Erlang parallel building blocks (2)

-behaviour(gen_server).

-export([start/0, start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-export([new_group/0, spawn/2, spawn_list/2, go/1, async_go/1, sync/1, barrier/0, barrier/1]). % , synced_barrier/0

-record(state, {
	pids=[],
	size=0,
	done=[],
	donesize=0,
	barrierlist=[],
	barriersize=0,
	initwaitlist=[],
	goed=false,
	sync=false,
	syncer
}).

% We can also manage sync groups using auxilary proxy process, which will manage it.
% It have some advantages: one can pass Group to other process and sync there,
%                          as well perform syncing in background, and then just sync with one process
%                          make_ref() is also not needed, as auxilary process is designed only for single purpose
%                          and queue processing will be faster, as well memory reclamation after syncing
%                          it also make it possible to write proxy using gen_server
% but also disadvantages: hidding functional representation of datastructures.

% super process API

new_group() ->
	{ok, Pid} = start_link(),
	Pid.

spawn(F, Pid) when is_function(F, 0) or is_function(F, 1) ->
	gen_server:cast(Pid, {spawn, F}),
	Pid.

spawn_list(FList, Pid) when is_list(FList) ->
	gen_server:cast(Pid, {spawn_list, FList}),
	Pid.

% go function allows spawning lots of processe easly by repeated calling spawn and/or spawn_list
% and then synchronizing start of all of them,
% actually process can already by running and computing, but they will block
% when trying to: perform barrier, end computations, communicate with parrent, etc.
% This is because all this actions needs to know what is the size
% of whole group, but before go() it can vary!
go(Pid) ->
	goed = gen_server:call(Pid, go, 600*1000), % set timeout to 10 minutes, instead of 5 seconds
	{Pid, goed}.

async_go(Pid) ->
	gen_server:cast(Pid, {async_go, self()}),
	Pid.

sync(Pid) ->
	synced = gen_server:call(Pid, sync, 600*1000), % set timeout to 10 minutes, instead of 5 seconds
	{Pid, synced}.



% sub process API

% private API
init_wait(Parent) ->
	gen_server:call(Parent, {init_wait, self()}, 60*1000).

iamdone(Parent) ->
	gen_server:cast(Parent, {iamdone, self()}),
	ok.

parent() -> get('$epbb2_parent').
parent(Parent) -> Parent.

% public API
barrier() ->
	Parent = parent(),
	barrier(Parent).

barrier(Parent) ->
	gen_server:call(Parent, {barrier, self()}, 600*1000).

%synced_barrier() ->
%	Parent = parent(),
%	synced_barrier(Parent).

%synced_barrier(Parent) ->
%	gen_server:call(Parent, {synced_barrier, self()}, 600*1000).



% gen_server API

start() ->
	gen_server:start(?MODULE, [], []).
start_link() ->
	gen_server:start_link(?MODULE, [], []).

init([]) ->
	{ok, #state{}}.

notify_barrier(BarrierList) ->
	% this can be done in background, in separate process, or in parallel
	lists:foreach(fun(P) ->
		gen_server:reply(P, ok)
	end, BarrierList).


go_go(State = #state{goed=false,initwaitlist=WaitList0,size=Size,barriersize=BarrierSize0,barrierlist=BarrierList0}) ->
	% this can be done in background, in separate process, or in parallel
	lists:foreach(fun(P) ->
		gen_server:reply(P, go)
	end, WaitList0),
	case BarrierSize0 of
		Size ->
			notify_barrier(BarrierList0),
			State#state{goed=true,initwaitlist=[],barriersize=0,barrierlist=[]};
		_ ->
			State#state{goed=true,initwaitlist=[]}
	end.

handle_call(sync, From, State = #state{sync=false,goed=true,size=Size,donesize=DoneSize}) ->
	case DoneSize of
		Size ->
			%{reply, synced, empty};
			{stop, normal, synced, empty};
		_ ->
			{noreply, State#state{sync=true,syncer=From}}
	end;
handle_call(go, _From, State = #state{goed=false}) ->
	State2 = go_go(State),
	{reply, goed, State2};
handle_call({barrier, _From2}, From, State = #state{goed=true,size=Size,barriersize=BarrierSize0,barrierlist=BarrierList0}) ->
	BarrierList = [From | BarrierList0],
	BarrierSize = BarrierSize0+1,
	case BarrierSize of
		Size ->
			notify_barrier(BarrierList),
			{noreply, State#state{barriersize=0,barrierlist=[]}};
		_ ->
			{noreply, State#state{barriersize=BarrierSize,barrierlist=BarrierList}}
	end;
handle_call({barrier, _From2}, From, State = #state{goed=false,barriersize=BarrierSize0,barrierlist=BarrierList0}) ->
	BarrierList = [From | BarrierList0],
	BarrierSize = BarrierSize0+1,
	{noreply, State#state{barriersize=BarrierSize,barrierlist=BarrierList}};
handle_call({init_wait, _From2}, _From, State = #state{goed=true}) ->
	{reply, go, State};
handle_call({init_wait, _From2}, From, State = #state{goed=false,initwaitlist=WaitList0}) ->
	{noreply, State#state{initwaitlist=[From | WaitList0]}}.

%handle_call(_, _, State = empty) ->
%	{noreply, State}. % let caller crash


sl(F, Parent) when is_function(F, 0) ->
	spawn_link(fun() ->
		go = init_wait(Parent), % TODO: we should get rid of init_wait
		                        % just start F(), eventually blocking in iamdone() or barrier()!
		put('$epbb2_parent', Parent),
		F(),
		iamdone(Parent)
	end);
sl(F, Parent) when is_function(F, 1) ->
	spawn_link(fun() ->
		go = init_wait(Parent),
		F(Parent),
		iamdone(Parent)
	end).


handle_cast({spawn, F}, State = #state{goed=false,pids=List,size=Size}) ->
	Parent = self(),
	Pid = sl(F, Parent),
	{noreply, State#state{pids=[Pid|List],size=Size+1}};
handle_cast({spawn_list, FList}, State = #state{goed=false,pids=List0,size=Size0}) ->
	Parent = self(),
	{NewSize, NewList} = lists:foldl(fun (F, {Size, List}) when is_function(F, 0) or is_function(F, 1) ->
		Pid = sl(F, Parent),
		{Size+1, [Pid | List]}
	end, {Size0, List0}, FList),
	{noreply, State#state{pids=NewList,size=NewSize}};
handle_cast({iamdone, From}, State = #state{goed=true,done=DoneList0,donesize=DoneSize0,size=Size}) when DoneSize0 < Size ->
	DoneSize = DoneSize0+1,
	if
		State#state.sync and (DoneSize == Size) ->
			gen_server:reply(State#state.syncer, synced),
			{stop, normal, empty};
		true ->
			{noreply, State#state{done=[From|DoneList0],donesize=DoneSize}}
	end;
handle_cast({iamdone, From}, State = #state{goed=false,done=DoneList0,donesize=DoneSize0}) ->
	DoneSize = DoneSize0+1,
	{noreply, State#state{done=[From|DoneList0],donesize=DoneSize}};
handle_cast({async_go, _From}, State = #state{goed=false}) ->
	State2 = go_go(State),
	{noreply, State2}.

%handle_cast(_, State = empty) ->
%	{noreply, State}.


handle_info(_Msg, _State) ->
	exit(badarg).


terminate(normal, empty) ->
	ok;
terminate(_Reason, _State) ->
	void.

code_change(_OldVsn, State, _Extra) ->
	NewState = State,
	{ok, NewState}.
