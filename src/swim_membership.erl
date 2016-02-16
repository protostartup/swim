-module(swim_membership).

-behavior(gen_server).

-include("swim.hrl").

-record(state, {
	  local_member                :: member(),
	  event_mgr_pid               :: pid() | module(),
	  incarnation        = 0      :: non_neg_integer(),
	  members            = #{}    :: maps:map(member(), member_state()),
	  suspicion_factor   = 5      :: pos_integer(),
	  protocol_period    = 1000   :: pos_integer()
	 }).

-record(member_state, {
	  status        = alive :: member_status(),
	  incarnation   = 0     :: non_neg_integer(),
	  last_modified         :: integer()
	 }).

-type member_state() :: #member_state{}.

-export([start_link/3, alive/3, suspect/3, faulty/3, members/1,
	 local_member/1, set_status/3, num_members/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, code_change/3,
	 terminate/2]).

num_members(Pid) ->
    gen_server:call(Pid, num_members).

local_member(Pid) ->
    gen_server:call(Pid, local).

set_status(Pid, Member, Status) ->
    gen_server:cast(Pid, {set_status, Member, Status}).

alive(Pid, Member, Incarnation) ->
    gen_server:call(Pid, {alive, Member, Incarnation}).

suspect(Pid, Member, Incarnation) ->
    gen_server:call(Pid, {suspect, Member, Incarnation}).

faulty(Pid, Member, Incarnation) ->
    gen_server:call(Pid, {faulty, Member, Incarnation}).

members(Pid) ->
    gen_server:call(Pid, members).

start_link(LocalMember, EventMgrPid, Opts) ->
    gen_server:start_link(?MODULE, [LocalMember, EventMgrPid, Opts], []).

handle_opts([], State) ->
    State;
handle_opts([{suspicion_factor, Val} | Rest], State) ->
    handle_opts(Rest, State#state{suspicion_factor=Val});
handle_opts([{protocol_period, Val} | Rest], State) ->
    handle_opts(Rest, State#state{protocol_period=Val});
handle_opts([{seeds, Seeds} | Rest], State) ->
    #state{members=Members} = State,
    NewMembers = lists:foldl(
		   fun(Member, Acc) ->
			   MemberState = #member_state{status=alive,
						       incarnation=0,
						       last_modified=erlang:monotonic_time()},
			   maps:put(Member, MemberState, Acc)
		   end, Members, Seeds),
    handle_opts(Rest, State#state{members=NewMembers});
handle_opts([_ | Rest], State) ->
    handle_opts(Rest, State).

init([LocalMember, EventMgrPid, Opts]) ->
    State = handle_opts(Opts, #state{local_member=LocalMember,
				     event_mgr_pid=EventMgrPid}),
    {ok, State}.

handle_call(num_members, _From, State) ->
    #state{members=Members} = State,
    {reply, maps:size(Members) + 1, State};
handle_call(local, _From, State) ->
    {reply, State#state.local_member, State};
handle_call(members, _From, State) ->
    #state{members=Members} = State,
    M = maps:fold(
	  fun(Member, MemberState, Acc) ->
		  #member_state{status=Status, incarnation=Inc} = MemberState,
		  [{Member, Status, Inc} | Acc]
	  end, [], Members),
    {reply, M, State};
handle_call({alive, Member, Incarnation}, _From, #state{local_member=Member} = State) ->
    #state{incarnation=CurrentIncarnation} = State,
    case Incarnation =< CurrentIncarnation of
	true ->
	    {reply, ok, State};
	false ->
	    {Events, NewState} = refute(Incarnation, State),
	    ok = publish_events(Events, State),
	    {reply, Events, NewState}
    end;
handle_call({alive, Member, Incarnation}, _From, State) ->
    #state{members=Members} = State,
    {Events, NewMembers} =
	case maps:find(Member, Members) of
	    {ok, MemberState} ->
		#member_state{incarnation=CurrentIncarnation} = MemberState,
		case Incarnation > CurrentIncarnation of
		    true ->
			NewState = MemberState#member_state{status=alive,
							    incarnation=Incarnation,
							    last_modified=erlang:monotonic_time()},
			Ms = maps:put(Member, NewState, Members),
			{[{alive, Member, Incarnation}], Ms};
		    false ->
			{[], Members}
		end;
	    error ->
		NewState = #member_state{status=alive,
					 incarnation=Incarnation,
					 last_modified=erlang:monotonic_time()},
		Ms = maps:put(Member, NewState, Members),
		{[{alive, Member, Incarnation}], Ms}
	end,
    ok = publish_events(Events, State),
    {reply, Events, State#state{members=NewMembers}};
handle_call({suspect, Member, Incarnation}, _From, #state{local_member=Member} = State) ->
    {Events, NewState} = refute(Incarnation, State),
    {reply, Events, NewState};
handle_call({suspect, Member, Incarnation}, _From, State) ->
    #state{members=Members} = State,
    {Events, NewMembers} =
	case maps:find(Member, Members) of
	    {ok, MemberState} ->
		case MemberState of
		    #member_state{status=suspect, incarnation=CurrentIncarnation}
		      when Incarnation > CurrentIncarnation ->
			NewState = MemberState#member_state{status=suspect,
							    incarnation=Incarnation,
							    last_modified=erlang:monotonic_time()},
			Ms = maps:put(Member, NewState, Members),
			_ = suspicion_timer(Member, NewState, State),
			{[{suspect, Member, Incarnation}], Ms};
		    #member_state{status=alive, incarnation=CurrentIncarnation}
		      when Incarnation >= CurrentIncarnation ->
			NewState = MemberState#member_state{status=suspect,
							    incarnation=Incarnation,
							    last_modified=erlang:monotonic_time()},
			Ms = maps:put(Member, NewState, Members),
			_ = suspicion_timer(Member, NewState, State),
			{[{suspect, Member, Incarnation}], Ms};
		    _ ->
			{[], Members}
		end;
	    error ->
		{[], Members}
	end,
    {reply, Events, State#state{members=NewMembers}};
handle_call({faulty, Member, Incarnation}, _From, #state{local_member=Member} = State) ->
    {Events, NewState} = refute(Incarnation, State),
    {reply, Events, NewState};
handle_call({faulty, Member, Incarnation}, _From, State) ->
    #state{members=Members} = State,
    {Events, NewMembers} =
	case maps:find(Member, Members) of
	    {ok, MemberState} ->
		#member_state{incarnation=CurrentIncarnation} = MemberState,
		case Incarnation < CurrentIncarnation of
		    true ->
			{[], Members};
		    false ->
			Ms = maps:remove(Member, Members),
			{[{faulty, Member, CurrentIncarnation}], Ms}
		end;
	    error ->
		{[], Members}
	end,
    ok = publish_events(Events, State),
    {reply, Events, State#state{members=NewMembers}};
handle_call(_Msg, _From, State) ->
    {noreply, State}.

handle_cast({set_status, Member, Status}, State) ->
    #state{members=Members} = State,
    {_Events, NewMembers} =
	case maps:find(Member, Members) of
	    {ok, MemberState} ->
		NewMemberState = MemberState#member_state{status=Status,
							  last_modified=erlang:monotonic_time()},
		Ms = maps:put(Member, NewMemberState, Members),
		case Status of
		    suspect ->
			_ = suspicion_timer(Member, NewMemberState, State),
			{[{suspect, Member, NewMemberState#member_state.incarnation}], Ms};
		    _ ->
			{[], Ms}
		end;
	    error ->
		{[], Members}
	end,
    {noreply, State#state{members=NewMembers}};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({suspect_timeout, Member, SuspectedAt}, State) ->
    #state{members=Members} = State,
    {Events, NewMembers} =
	case maps:find(Member, Members) of
	    {ok, MemberState} ->
		case MemberState of
		    #member_state{incarnation=SuspectedAt, status=suspect} ->
			Ms = maps:remove(Member, Members),
			{[{faulty, Member, SuspectedAt}], Ms};
		    _ ->
			{[], Members}
		end;
	    error ->
		{[], Members}
	end,
    ok = publish_events(Events, State),
    {noreply, State#state{members=NewMembers}};
handle_info(_Info, State) ->
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.

suspicion_timeout(State) ->
    #state{members=Members, suspicion_factor=Factor,
	   protocol_period=ProtocolPeriod} = State,
    round(math:log(maps:size(Members) + 2)) * Factor * ProtocolPeriod.

suspicion_timer(Member, MemberState, State) ->
    #member_state{incarnation=Incarnation} = MemberState,
    Msg = {suspect_timeout, Member, Incarnation},
    erlang:send_after(suspicion_timeout(State), self(), Msg).

refute(Incarnation, #state{incarnation=CurrentIncarnation} = State)
  when Incarnation >= CurrentIncarnation ->
    #state{local_member=LocalMember} = State,
    NewIncarnation = Incarnation + 1,
    {[{alive, LocalMember, NewIncarnation}], State#state{incarnation=NewIncarnation}};
refute(Incarnation, #state{incarnation=CurrentIncarnation} = State)
  when Incarnation < CurrentIncarnation ->
    #state{local_member=LocalMember} = State,
    {[{alive, LocalMember, CurrentIncarnation}], State}.

publish_events(Events, State) ->
    #state{event_mgr_pid=EventMgrPid} = State,
    _ = [swim_broadcasts:membership(EventMgrPid, Event) || Event <- Events],
    ok.
