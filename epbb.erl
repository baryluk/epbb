-module(epbb).
-author('baryluk@smp.if.uj.edu.pl').

% Erlang parallel building blocks

-export([new_group/0, spawn/2, spawn_list/2, go/1, sync/1]).

%
% Group = epbb:new_group(),
% Group1 = epbb:spawn_list([
%                  fun() -> do_something(1) end,
%                  fun() -> do_something(2) end,
%                  fun() -> do_something(3) end
%             ], Group),
% epbb:sync(Group1).
%
%
% If you want to managa multiple groups at once, or groups are very large, please use rather eppb2.
% If you have only one group at once, and less than 10 processes in group,
% as well no other message passing going around  this module will make smaller overhead and
% perform better.

% Ref is needed because we can have multiple sync groups running on single processor.
new_group() ->
	{0, make_ref(), []}.

spawn(F, {Size, Ref, List}) when is_function(F, 0) ->
	Parent = self(),
	Pid = spawn_link(fun() -> F(), Parent ! {self(), eppb_done, Ref} end),
	{Size+1, Ref, [Pid | List]}.

spawn_list(FList, {Size0, Ref, List0}) ->
	Parent = self(),
	{NewSize, NewList} = lists:foldl(fun (F, {Size, List}) when is_function(F, 0) ->
		Pid = spawn_link(fun() -> F(), Parent ! {self(), eppb_done, Ref} end),
		{Size+1, [Pid | List]}
	end, {Size0, List0}, FList),
	{NewSize, Ref, NewList}.

go({Size, Ref, List} = SRL) ->
	SRL.

sync({Size, Ref, List}) ->
	Timeout = 600000,
	if % choose scheme to use
		Size >= 40 ->
			sync_tree(Ref, Size, List, Timeout);
		Size >= 20 ->
			sync_list2(Ref, Size, List, [], Timeout);
		true ->
			sync_list(Ref, List, Timeout)
	end.

% Sync list is for small groups.
% List handling is fast, however it processes messages out-of-order, which will mean
% message queue can grow, and it will be rescaned on each message,
% making O(n^2) worst case. Processing messages in-order will
% still leave it O(n^2) - message queue will not grow, but lists:delete/2
% will be also processed in O(n) time, and will make additional memory allocations,
% (which in case of removing from message queue instead can be avoided).
% Other possibility is to just dequeue N messages with proper Ref, add to list, sort it, then compare with
% our list. This makes O(n log n).
sync_list(Ref, [], _Timeout) ->
	sync_list_end(Ref);
sync_list(Ref, [Pid | Rest], Timeout) ->
	receive
		{Pid, eppb_done, Ref} ->
			sync_list(Ref, Rest, Timeout) % check at the end
		after Timeout ->
			exit(timeout)
	end.

% Just check if nothing strange appears in queue.
sync_list_end(Ref) ->
	receive
		{_Pid, eppb_done, Ref} ->
			exit(something_wrong)
		after 0 ->
			ok
	end.

sync_list2(Ref, 0, Pids, Acc, _Timeout) ->
	X = (lists:sort(Pids) =:= lists:sort(Acc)),
	if
		X ->
			sync_list_end(Ref); % check at the end
		true ->
			erlang:exit(something_wrong)
	end;
sync_list2(Ref, N, Pids, Acc, Timeout) ->
	receive
		{Pid, eppb_done, Ref} ->
			sync_list2(Ref, N-1, Pids, [Pid | Acc], Timeout)
		after Timeout ->
			exit(timeout)
	end.

sync_tree(Ref, N, List, Timeout) ->
	Tree0 = gb_trees:empty(),
	Tree = lists:foldl(fun(Pid, Acc) ->
		gb_trees:insert(Pid, 1, Acc)
	end, Tree0, List),
	% wlozyc liste List
	sync_tree2(Ref, N, Tree, Timeout).

sync_tree2(Ref, N, Tree, Timeout) ->
	receive
		{Pid, eppb_done, Ref} ->
			NewTree = gb_trees:delete(Pid, Tree),
			sync_tree2(Ref, N-1, NewTree, Timeout)
		after Timeout ->
			exit(timeout)
	end.


% We can also support multiple-sync-groups in single sync,
% by receiving all eppb_done independed of the Ref, and
% storing them in tree with Ref as key.
% Then we can process them easier and faster (especially considering message queue).
% However it starts to be complicated,
% and proxy server approach (eppb2) should be easier
% more managable, faster (by separate message queues from start) and more fault tolerant.
