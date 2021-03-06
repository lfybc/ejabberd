%%%----------------------------------------------------------------------
%%% File    : ejabberd_receiver.erl
%%% Author  : Alexey Shchepin <alexey@process-one.net>
%%% Purpose : Socket receiver for C2S and S2S connections
%%% Created : 10 Nov 2003 by Alexey Shchepin <alexey@process-one.net>
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2008   Process-one
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%                         
%%% You should have received a copy of the GNU General Public License
%%% along with this program; if not, write to the Free Software
%%% Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA
%%% 02111-1307 USA
%%%
%%%----------------------------------------------------------------------

-module(ejabberd_receiver).
-author('alexey@process-one.net').

-behaviour(gen_server).

%% API
-export([start_link/4,
	 start/3,
	 start/4,
	 change_shaper/2,
	 reset_stream/1,
	 starttls/2,
	 compress/2,
	 become_controller/2,
	 close/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-include("ejabberd.hrl").

-record(state, {socket,
		sock_mod,
		shaper_state,
		c2s_pid,
		max_stanza_size,
		xml_stream_state,
		timeout}).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------
start_link(Socket, SockMod, Shaper, MaxStanzaSize) ->
    gen_server:start_link(
      ?MODULE, [Socket, SockMod, Shaper, MaxStanzaSize], []).

%%--------------------------------------------------------------------
%% Function: start() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------
start(Socket, SockMod, Shaper) ->
    start(Socket, SockMod, Shaper, infinity).

start(Socket, SockMod, Shaper, MaxStanzaSize) ->
    {ok, Pid} = supervisor:start_child(
		  ejabberd_receiver_sup,
		  [Socket, SockMod, Shaper, MaxStanzaSize]),
    Pid.

change_shaper(Pid, Shaper) ->
    gen_server:cast(Pid, {change_shaper, Shaper}).

reset_stream(Pid) ->
    gen_server:call(Pid, reset_stream).

starttls(Pid, TLSSocket) ->
    gen_server:call(Pid, {starttls, TLSSocket}).

compress(Pid, ZlibSocket) ->
    gen_server:call(Pid, {compress, ZlibSocket}).

become_controller(Pid, C2SPid) ->
    gen_server:call(Pid, {become_controller, C2SPid}).

close(Pid) ->
    gen_server:cast(Pid, close).

%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, State} |
%%                         {ok, State, Timeout} |
%%                         ignore               |
%%                         {stop, Reason}
%% Description: Initiates the server
%%--------------------------------------------------------------------
init([Socket, SockMod, Shaper, MaxStanzaSize]) ->
    ShaperState = shaper:new(Shaper),
    Timeout = case SockMod of
		  ssl ->
		      20;
		  _ ->
		      infinity
	      end,
    {ok, #state{socket = Socket,
		sock_mod = SockMod,
		shaper_state = ShaperState,
		max_stanza_size = MaxStanzaSize,
		timeout = Timeout}}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------
handle_call({starttls, TLSSocket}, _From,
	    #state{xml_stream_state = XMLStreamState,
		   c2s_pid = C2SPid,
		   max_stanza_size = MaxStanzaSize} = State) ->
    if
	XMLStreamState /= undefined ->
	    xml_stream:close(XMLStreamState);
	true ->
	    ok
    end,
    NewXMLStreamState = xml_stream:new(C2SPid, MaxStanzaSize),
    NewState = State#state{socket = TLSSocket,
			   sock_mod = tls,
			   xml_stream_state = NewXMLStreamState},
    case tls:recv_data(TLSSocket, "") of
	{ok, TLSData} ->
	    {reply, ok, process_data(TLSData, NewState)};
	{error, _Reason} ->
	    {stop, normal, ok, NewState}
    end;
handle_call({compress, ZlibSocket}, _From,
	    #state{xml_stream_state = XMLStreamState,
		   c2s_pid = C2SPid,
		   max_stanza_size = MaxStanzaSize} = State) ->
    xml_stream:close(XMLStreamState),
    NewXMLStreamState = xml_stream:new(C2SPid, MaxStanzaSize),
    NewState = State#state{socket = ZlibSocket,
			   sock_mod = ejabberd_zlib,
			   xml_stream_state = NewXMLStreamState},
    case ejabberd_zlib:recv_data(ZlibSocket, "") of
	{ok, ZlibData} ->
	    {reply, ok, process_data(ZlibData, NewState)};
	{error, _Reason} ->
	    {stop, normal, ok, NewState}
    end;
handle_call(reset_stream, _From,
	    #state{xml_stream_state = XMLStreamState,
		   c2s_pid = C2SPid,
		   max_stanza_size = MaxStanzaSize} = State) ->
    xml_stream:close(XMLStreamState),
    NewXMLStreamState = xml_stream:new(C2SPid, MaxStanzaSize),
    Reply = ok,
    {reply, Reply, State#state{xml_stream_state = NewXMLStreamState}};
handle_call({become_controller, C2SPid}, _From, State) ->
    XMLStreamState = xml_stream:new(C2SPid, State#state.max_stanza_size),
    NewState = State#state{c2s_pid = C2SPid,
			   xml_stream_state = XMLStreamState},
    activate_socket(NewState),
    Reply = ok,
    {reply, Reply, NewState};
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------
handle_cast({change_shaper, Shaper}, State) ->
    NewShaperState = shaper:new(Shaper),
    {noreply, State#state{shaper_state = NewShaperState}};
handle_cast(close, State) ->
    {stop, normal, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info({Tag, _TCPSocket, Data},
	    #state{socket = Socket,
		   sock_mod = SockMod} = State)
  when (Tag == tcp) or (Tag == ssl) ->
    case SockMod of
	tls ->
	    case tls:recv_data(Socket, Data) of
		{ok, TLSData} ->
		    {noreply, process_data(TLSData, State)};
		{error, _Reason} ->
		    {stop, normal, State}
	    end;
	ejabberd_zlib ->
	    case ejabberd_zlib:recv_data(Socket, Data) of
		{ok, ZlibData} ->
		    {noreply, process_data(ZlibData, State)};
		{error, _Reason} ->
		    {stop, normal, State}
	    end;
	_ ->
	    {noreply, process_data(Data, State)}
    end;
handle_info({Tag, _TCPSocket}, State)
  when (Tag == tcp_closed) or (Tag == ssl_closed) ->
    {stop, normal, State};
handle_info({Tag, _TCPSocket, Reason}, State)
  when (Tag == tcp_error) or (Tag == ssl_error) ->
    case Reason of
	timeout ->
	    {noreply, State};
	_ ->
	    {stop, normal, State}
    end;
handle_info({timeout, _Ref, activate}, State) ->
    activate_socket(State),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%% Description: This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
%%--------------------------------------------------------------------
terminate(_Reason, #state{xml_stream_state = XMLStreamState,
			  c2s_pid = C2SPid} = State) ->
    xml_stream:close(XMLStreamState),
    if
	C2SPid /= undefined ->
	    gen_fsm:send_event(C2SPid, closed);
	true ->
	    ok
    end,
    catch (State#state.sock_mod):close(State#state.socket),
    ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

activate_socket(#state{socket = Socket,
		       sock_mod = SockMod}) ->
    PeerName =
	case SockMod of
	    gen_tcp ->
		inet:setopts(Socket, [{active, once}]),
		inet:peername(Socket);
	    _ ->
		SockMod:setopts(Socket, [{active, once}]),
		SockMod:peername(Socket)
	end,
    case PeerName of
	{error, _Reason} ->
	    self() ! {tcp_closed, Socket};
	{ok, _} ->
	    ok
    end.

process_data(Data,
	     #state{xml_stream_state = XMLStreamState,
		    shaper_state = ShaperState,
		    c2s_pid = C2SPid} = State) ->
    ?DEBUG("Received XML on stream = ~p", [binary_to_list(Data)]),
    XMLStreamState1 = xml_stream:parse(XMLStreamState, Data),
    {NewShaperState, Pause} = shaper:update(ShaperState, size(Data)),
    if
	C2SPid == undefined ->
	    ok;
	Pause > 0 ->
	    erlang:start_timer(Pause, self(), activate);
	true ->
	    activate_socket(State)
    end,
    State#state{xml_stream_state = XMLStreamState1,
		shaper_state = NewShaperState}.

