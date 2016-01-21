-module(swim_membership_v2_tests).

-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(ME, {{127,0,0,1}, 5000}).
-define(SUT, swim_membership_v2).

-behavior(proper_statem).

-export([command/1, initial_state/0, next_state/3, postcondition/3,
	 precondition/2]).

-type member_status() :: alive | suspect | faulty.
-type incarnation() :: non_neg_integer().
-type transmissions() :: non_neg_integer().
-type member() :: {inet:ip_address(), inet:port_number()}.

-record(state, {
	  me :: member(),
	  incarnation = 0 :: incarnation(),
	  members = [] :: [{member(), member_status(), incarnation()}],
	  events = [] :: list({member_status(), member(), incarnation(), transmissions()})
	 }).

membership_v2_local_member_test() ->
    {ok, Membership} = swim_membership_v2:start_link(?ME, []),
    ?assertMatch(?ME, swim_membership_v2:local_member(Membership)).

membership_v2_suspect_timeout_test() ->
    Seed = {{10,10,10,10}, 5000},
    {ok, Membership} = swim_membership_v2:start_link(?ME,
						     [{suspicion_factor, 1},
						      {protocol_period, 100},
						      {seeds, [Seed]}]),
    ok = swim_membership_v2:suspect(Membership, Seed, 1),
    ok = timer:sleep(100),
    Events = lists:map(
	       fun({membership, {S, M, _I}}) ->
		       {S, M}
	       end, swim_membership_v2:events(Membership)),
    ?assert(lists:member({faulty, Seed}, Events)).

membership_v2_suspect_timeout_refute_test() ->
    Seed = {{10,10,10,10}, 5000},
    {ok, Membership} = swim_membership_v2:start_link(?ME,
						     [{suspicion_factor, 10},
						      {protocol_period, 5000},
						      {seeds, [Seed]}]),
    ok = swim_membership_v2:suspect(Membership, Seed, 1),
    ok = swim_membership_v2:alive(Membership, Seed, 2),
    Events = lists:map(fun({membership, {S, M, I}}) ->
			       {S, M, I}
		       end, swim_membership_v2:events(Membership)),
    [?assertNot(lists:member({suspect, Seed, 1}, Events)),
     ?assert(lists:member({alive, Seed, 2}, Events))].

membership_v2_test_() ->
    {timeout, 60,
     ?_assert(proper:quickcheck(prop_membership_v2(), [{numtests, 500}, {to_file, user}]))}.

g_ipv4_address() ->
    tuple([integer(0, 255) || _ <- lists:seq(0, 3)]).

g_ipv6_address() ->
    tuple([integer(0, 65535) || _ <- lists:seq(0, 7)]).

g_ip_address() ->
    oneof([g_ipv4_address(), g_ipv6_address()]).

g_port_number() ->
    integer(0, 65535).

g_incarnation() ->
    integer(0, inf).

g_new_member() ->
    {g_ip_address(), g_port_number()}.

g_local_member(State) ->
    exactly(State#state.me).

g_non_local_member(State) ->
    ?LET({Member, _CurrentStatus, _CurrentInc},
	 oneof(State#state.members),
	 Member).

g_existing_member(State) ->
    oneof([g_local_member(State), g_non_local_member(State)]).

g_member(State) ->
    frequency([{1, g_new_member()}] ++
	      [{3, g_existing_member(State)} || State#state.members /= []]).

initial_state() ->
    #state{me=?ME}.

command(State) ->
    oneof([
	   {call, ?SUT, alive, [{var, sut}, g_member(State), g_incarnation()]},
	   {call, ?SUT, suspect, [{var, sut}, g_member(State), g_incarnation()]},
	   {call, ?SUT, faulty, [{var, sut}, g_member(State), g_incarnation()]},
	   {call, ?SUT, members, [{var, sut}]},
	   {call, ?SUT, events, [{var, sut}, integer()]}
	  ]).

precondition(_State, _Call) ->
    true.

postcondition(S, {call, _Mod, members, _Args}, Members) ->
    #state{members=KnownMembers} = S,
    ordsets:subtract(ordsets:from_list(KnownMembers),
		     ordsets:from_list(Members)) == [];
postcondition(S, {call, _Mod, events, _Args}, Events) ->
    #state{events=KnownEvents, me=Me,
	   incarnation=LocalIncarnation} = S,
    lists:all(
      fun({membership, {Status, Member, Incarnation}}) ->
	      case lists:keyfind(Member, 2, KnownEvents) of
		  {Status, Member, Incarnation, _T} ->
		      true;
		  false ->
		      case {Member, LocalIncarnation} of
			  {Me, Incarnation} ->
			      true;
			  _Other ->
			      false
		      end;
		  _Other ->
		      false
	      end
      end, Events);
postcondition(_State, {call, _Mod, _, _Args}, _R) ->
    true.

next_state(S, _V, {call, _Mod, members, _Args}) ->
    S;
next_state(S, _V, {call, _Mod, alive, [_Pid, Member, Incarnation]}) ->
    #state{members=KnownMembers, events=Events,
	  incarnation=LocalIncarnation} = S,
    case S#state.me == Member of
	true ->
	    case Incarnation > LocalIncarnation of
		true ->
		    S#state{events=[{alive, Member, Incarnation + 1, 0} | Events],
			    incarnation=Incarnation + 1};
		false ->
		    S#state{events=[{alive, Member, LocalIncarnation, 0} | Events]}
	    end;
	false ->
	    case lists:keytake(Member, 1, KnownMembers) of
		false ->
		    NewEvents = [{alive, Member, Incarnation, 0} | Events],
		    NewMembers = [{Member, alive, Incarnation} | KnownMembers],
		    S#state{members=NewMembers, events=NewEvents};
		{value, {Member, _CurrentStatus, CurrentIncarnation}, Rest}
		  when Incarnation > CurrentIncarnation ->
		    NewEvents = [{alive, Member, Incarnation, 0} | Events],
		    NewMembers = [{Member, alive, Incarnation} | Rest],
		    S#state{members=NewMembers, events=NewEvents};
		_ ->
		    S
	    end
    end;
next_state(#state{me=Me} = S, _V, {call, _Mod, suspect, [_Pid, Me, Incarnation]}) ->
    #state{incarnation=LocalIncarnation, events=Events} = S,
    case Incarnation >= LocalIncarnation of
	true ->
	    S#state{events=[{alive, Me, Incarnation + 1, 0} | Events],
		    incarnation=Incarnation + 1};
	false ->
	    S#state{events=[{alive, Me, LocalIncarnation, 0} | Events]}
    end;
next_state(S, _V, {call, _Mod, suspect, [_Pid, Member, Incarnation]}) ->
    #state{members=KnownMembers, events=Events} = S,
    case lists:keytake(Member, 1, KnownMembers) of
	false ->
	    S;
	{value, {Member, _CurrentStatus, CurrentIncarnation}, Rest}
	  when Incarnation >= CurrentIncarnation ->
	    NewEvents = [{suspect, Member, Incarnation, 0} | Events],
	    NewMembers = [{Member, suspect, Incarnation} | Rest],
	    S#state{members=NewMembers, events=NewEvents};
	_ ->
	    S
    end;
next_state(#state{me=Me} = S, _V, {call, _Mod, faulty, [_, Me, Incarnation]}) ->
    #state{incarnation=LocalIncarnation, events=Events} = S,
    case Incarnation >= LocalIncarnation of
	true ->
	    S#state{incarnation=Incarnation + 1,
		    events=[{alive, Me, Incarnation + 1, 0} | Events]};
	false ->
	    S#state{events=[{alive, Me, LocalIncarnation, 0} | Events]}
    end;
next_state(S, _V, {call, _Mod, faulty, [_Pid, Member, Incarnation]}) ->
    #state{members=KnownMembers, events=Events} = S,
    case lists:keytake(Member, 1, KnownMembers) of
	false ->
	    S;
	{value, {Member, _CurrentStatus, CurrentIncarnation}, Rest}
	  when Incarnation >= CurrentIncarnation ->
	    NewEvents = [{faulty, Member, CurrentIncarnation, 0} | Events],
	    S#state{members=Rest, events=NewEvents};
	_ ->
	    S
    end;
next_state(S, _V, {call, _Mod, events, [_Pid, _Size]}) ->
    S.

prop_membership_v2() ->
    ?FORALL(Cmds, commands(?MODULE),
	    ?TRAPEXIT(
	       begin
		   {ok, Pid} = ?SUT:start_link(?ME, [{suspicion_factor, 1}, {protocol_period, 1}]),
		   {H, S, R} = run_commands(?MODULE, Cmds, [{sut, Pid}]),
		   ?WHENFAIL(
		      io:format("History: ~p\nState: ~p\nResult: ~p\n",
				[H, S, R]),
		      aggregate(command_names(Cmds), R =:= ok))
	       end)).