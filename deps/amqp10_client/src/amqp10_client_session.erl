-module(amqp10_client_session).

-behaviour(gen_fsm).

-include("amqp10_client.hrl").
-include("rabbit_amqp1_0_framing.hrl").

%% Public API.
-export(['begin'/1,
         'end'/1,
         attach/5,
         transfer/3,
         flow/3
        ]).

%% Private API.
-export([start_link/2,
         socket_ready/2
        ]).

%% gen_fsm callbacks.
-export([init/1,
         unmapped/2,
         begin_sent/2,
         begin_sent/3,
         mapped/2,
         mapped/3,
         end_sent/2,
         handle_event/3,
         handle_sync_event/4,
         handle_info/3,
         terminate/3,
         code_change/4]).

-define(MAX_SESSION_WINDOW_SIZE, 65535).
-define(DEFAULT_MAX_HANDLE, 16#ffffffff).

-type transfer_id() :: non_neg_integer().
-type link_handle() :: non_neg_integer().
-type link_name() :: binary().
-type role() :: sender | receiver.
-type link_source() :: binary() | undefined.
-type link_target() :: {pid, pid()} | binary() | undefined.

-record(link,
        {name :: link_name(),
         output_handle :: link_handle(),
         input_handle :: link_handle() | undefined,
         role :: role(),
         source :: link_source(),
         target :: link_target(),
         delivery_count = 0 :: non_neg_integer(),
         link_credit = 0 :: non_neg_integer(),
         available = undefined :: non_neg_integer() | undefined,
         drain = false :: boolean()
         }).

-record(state,
        {channel :: pos_integer(),
         remote_channel :: pos_integer() | undefined,
         next_incoming_id = 0 :: transfer_id(),
         incoming_window = ?MAX_SESSION_WINDOW_SIZE :: non_neg_integer(),
         next_outgoing_id = 0 :: transfer_id(),
         outgoing_window = ?MAX_SESSION_WINDOW_SIZE  :: non_neg_integer(),
         remote_incoming_window = 0 :: non_neg_integer(),
         remote_outgoing_window = 0 :: non_neg_integer(),
         reader :: pid(),
         socket :: gen_tcp:socket() | undefined,
         links = #{} :: #{link_handle() => #link{}},
         link_index = #{} :: #{link_name() => link_handle()}, % maps incoming handle to outgoing
         link_handle_index = #{} :: #{link_handle() => link_handle()}, % maps incoming handle to outgoing
         next_link_handle = 0 :: link_handle(),
         next_delivery_id = 0 :: non_neg_integer(),
         early_attach_requests = [] :: [term()],
         pending_attach_requests = #{} :: #{link_name() => {pid(), any()}}
        }).

%% -------------------------------------------------------------------
%% Public API.
%% -------------------------------------------------------------------

-spec 'begin'(pid()) -> supervisor:startchild_ret().

'begin'(Connection) ->
    %% The connection process is responsible for allocating a channel
    %% number and contact the sessions supervisor to start a new session
    %% process.
    amqp10_client_connection:begin_session(Connection).

-spec 'end'(pid()) -> ok.

'end'(Pid) ->
    gen_fsm:send_event(Pid, 'end').

-spec attach(pid(), binary(), role(), #'v1_0.source'{}, #'v1_0.target'{}) ->
    {ok, link_handle()}.
attach(Session, Name, Role, Source, Target) ->
    gen_fsm:sync_send_event(Session, {attach, {Name, Role, Source, Target}}).

-spec transfer(pid(), #'v1_0.transfer'{}, any()) -> ok.
transfer(Session, Transfer, Message) ->
    gen_fsm:sync_send_event(Session, {transfer, {Transfer, Message}}).

flow(Session, Handle, Flow) ->
    gen_fsm:send_event(Session, {flow, Handle, Flow}).

%% -------------------------------------------------------------------
%% Private API.
%% -------------------------------------------------------------------

start_link(Channel, Reader) ->
    gen_fsm:start_link(?MODULE, [Channel, Reader], []).

-spec socket_ready(pid(), gen_tcp:socket()) -> ok.

socket_ready(Pid, Socket) ->
    gen_fsm:send_event(Pid, {socket_ready, Socket}).

%% -------------------------------------------------------------------
%% gen_fsm callbacks.
%% -------------------------------------------------------------------

init([Channel, Reader]) ->
    amqp10_client_frame_reader:register_session(Reader, self(), Channel),
    State = #state{channel = Channel, reader = Reader},
    {ok, unmapped, State}.

unmapped({socket_ready, Socket}, State) ->
    State1 = State#state{socket = Socket},
    case send_begin(State1) of
        ok    -> {next_state, begin_sent, State1};
        Error -> {stop, Error, State1}
    end.

begin_sent(#'v1_0.begin'{remote_channel = {ushort, RemoteChannel},
                         next_outgoing_id = {uint, NOI},
                         incoming_window = {uint, InWindow},
                         outgoing_window = {uint, OutWindow}
                        },
           #state{early_attach_requests = EARs} =  State) ->
    error_logger:info_msg("-- SESSION BEGUN (~b <-> ~b) --~n",
                          [State#state.channel, RemoteChannel]),
    State1 = State#state{remote_channel = RemoteChannel},
    State2 = lists:foldr(fun({From, Attach}, S) ->
                                 handle_attach(fun send/2, Attach, From, S)
                         end, State1, EARs),
    {next_state, mapped, State2#state{early_attach_requests = [],
                                      next_incoming_id = NOI,
                                      remote_incoming_window = InWindow,
                                      remote_outgoing_window = OutWindow
                                     }}.

begin_sent({attach, Attach}, From,
                      #state{early_attach_requests = EARs} = State) ->
    {next_state, begin_sent,
     State#state{early_attach_requests = [{From, Attach} | EARs]}}.

mapped('end', State) ->
    %% We send the first end frame and wait for the reply.
    case send_end(State) of
        ok              -> {next_state, end_sent, State};
        {error, closed} -> {stop, normal, State};
        Error           -> {stop, Error, State}
    end;
mapped({flow, OutHandle, #'v1_0.flow'{link_credit = {uint, LinkCredit}} = Flow0},
       #state{links = Links,
              next_incoming_id = NII,
              next_outgoing_id = NOI,
              outgoing_window = OutWin,
              incoming_window = InWin
             } = State) ->
    #{OutHandle := #link{output_handle = H,
                          role = receiver,
                          delivery_count = DeliveryCount,
                          available = _Available} = Link} = Links,
    Flow = Flow0#'v1_0.flow'{handle = pack_uint(H),
                             next_incoming_id = pack_uint(NII),
                             next_outgoing_id = pack_uint(NOI),
                             outgoing_window = pack_uint(OutWin),
                             incoming_window = pack_uint(InWin),
                             delivery_count = pack_uint(DeliveryCount)
                             },
    error_logger:info_msg("FLOW ~p~n", [Flow]),
    ok = send(Flow, State),
    {next_state, mapped,
     State#state{links = Links#{OutHandle =>
                                Link#link{link_credit = LinkCredit}}}};

mapped(#'v1_0.end'{}, State) ->
    %% We receive the first end frame, reply and terminate.
    _ = send_end(State),
    {stop, normal, State};
mapped(#'v1_0.attach'{name = {utf8, Name},
                      initial_delivery_count = IDC,
                      handle = {uint, InHandle}} = Attach,
        #state{links = Links, link_index = LinkIndex,
               link_handle_index = LHI,
               pending_attach_requests = PARs} = State) ->
    error_logger:info_msg("ATTACH ~p STATE ~p", [Attach, State]),
    #{Name := From} = PARs,
    #{Name := OutHandle} = LinkIndex,
    #{OutHandle := Link0} = Links,
    gen_fsm:reply(From, {ok, OutHandle}),
    Link = Link0#link{input_handle = InHandle,
                      delivery_count = unpack(IDC)},
    {next_state, mapped,
     State#state{links = Links#{OutHandle => Link},
                 link_handle_index = LHI#{InHandle => OutHandle},
                 pending_attach_requests = maps:remove(Name, PARs)}};

mapped(#'v1_0.flow'{handle = {uint, InHandle},
                    next_outgoing_id = {uint, NOI},
                    outgoing_window = {uint, OutWin},
                    delivery_count = {uint, DeliveryCount},
                    available = Available },
       #state{links = Links} = State0) ->

    {ok, #link{output_handle = OutHandle} = Link} =
        find_link_by_input_handle(InHandle, State0),
    Links1 = Links#{OutHandle => Link#link{delivery_count = DeliveryCount,
                                           available = unpack(Available)}},
    State = State0#state{next_incoming_id = NOI,
                         incoming_window = OutWin,
                         links = Links1},
    {next_state, mapped, State};

mapped([#'v1_0.transfer'{handle = {uint, InHandle}} = Transfer | Message],
                         #state{links = Links} =  State0) ->
    {ok, #link{target = {pid, TargetPid},
               delivery_count = DC,
               link_credit = Credit} = Link} =
        find_link_by_input_handle(InHandle, State0),

    TargetPid ! {message, Message},

    error_logger:info_msg("TRANSFER RECEIVED  ~p", [Transfer]),
    State = State0#state{
              links = Links#{InHandle => Link#link{delivery_count = DC+1,
                                                   link_credit = Credit-1}}},
    {next_state, mapped, State};
mapped(Frame, State) ->
    error_logger:info_msg("SESS UNANDLED FRAME ~p STATE ~p", [Frame, State]),
    {next_state, mapped, State}.

mapped({transfer, {#'v1_0.transfer'{handle = {uint, Handle}} = Transfer0,
                  Message}}, _From, #state{links = Links,
                                           next_outgoing_id = NOI,
                                           next_delivery_id = NDI} = State) ->
    % TODO: handle flow
    #{Handle := _Link} = Links,
    % use the delivery-id as the tag for now
    DeliveryTag = erlang:integer_to_binary(NDI),
    % augment transfer with session stuff
    Transfer = Transfer0#'v1_0.transfer'{delivery_id = {uint, NDI},
                                         delivery_tag = {binary, DeliveryTag}},
    ok = send_transfer(Transfer, Message, State),
    % reply after socket write
    % TODO when using settle = false delay reply until disposition
    {reply, ok, mapped, State#state{next_delivery_id = NDI+1,
                                    next_outgoing_id = NOI+1}};

mapped({attach, Attach}, From, State) ->
    State1 = handle_attach(fun send/2, Attach, From, State),
    {next_state, mapped, State1}.


end_sent(#'v1_0.end'{}, State) ->
    {stop, normal, State}.

handle_event(_Event, StateName, State) ->
    {next_state, StateName, State}.

handle_sync_event(_Event, _From, StateName, State) ->
    Reply = ok,
    {reply, Reply, StateName, State}.

handle_info(_Info, StateName, State) ->
    {next_state, StateName, State}.

terminate(Reason, _StateName, #state{channel = Channel,
                                     remote_channel = RemoteChannel,
                                     reader = Reader}) ->
    case Reason of
        normal -> amqp10_client_frame_reader:unregister_session(
                    Reader, self(), Channel, RemoteChannel);
        _      -> ok
    end,
    ok.

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%% -------------------------------------------------------------------
%% Internal functions.
%% -------------------------------------------------------------------

send_begin(#state{socket = Socket,
                  next_outgoing_id = NextOutId,
                  incoming_window = InWin,
                  outgoing_window = OutWin} = State) ->
    Begin = #'v1_0.begin'{
               next_outgoing_id = pack_uint(NextOutId),
               incoming_window = pack_uint(InWin),
               outgoing_window = pack_uint(OutWin)
              },
    Frame = encode_frame(Begin, State),
    gen_tcp:send(Socket, Frame).

send_end(#state{socket = Socket} = State) ->
    End = #'v1_0.end'{},
    Frame = encode_frame(End, State),
    gen_tcp:send(Socket, Frame).

encode_frame(Record, #state{channel = Channel}) ->
    Encoded = rabbit_amqp1_0_framing:encode_bin(Record),
    rabbit_amqp1_0_binary_generator:build_frame(Channel, Encoded).

send(Record, #state{socket = Socket} = State) ->
    Frame = encode_frame(Record, State),
    gen_tcp:send(Socket, Frame).

encode_transfer_frame(Transfer, Payload0, #state{channel = Channel}) ->
    Encoded = rabbit_amqp1_0_framing:encode_bin(Transfer),
    Payload = rabbit_amqp1_0_framing:encode_bin(Payload0),
    rabbit_amqp1_0_binary_generator:build_frame(Channel, [Encoded, Payload]).

% TODO large messages need to be split into several frames
send_transfer(Transfer, Payload, #state{socket = Socket} = State) ->
    Frame = encode_transfer_frame(Transfer, Payload, State),
    gen_tcp:send(Socket, Frame).

handle_attach(Send, {Name, Role, Source, Target}, {FromPid, _} = From,
      #state{next_link_handle = Handle, links = Links,
             pending_attach_requests = PARs,
             link_index = LinkIndex} = State) ->

    % create attach frame
    Attach = #'v1_0.attach'{name = {utf8, Name}, role = Role == receiver,
                            handle = {uint, Handle}, source = Source,
                            initial_delivery_count = {uint, 0}, %TODO don't send when receiver?
                            target = Target},
    ok = Send(Attach, State),
    {T, S} = case Role of
                 receiver -> {{pid, FromPid}, Source#'v1_0.source'.address};
                 sender -> {Source#'v1_0.source'.address, undefined}
             end,
    Link = #link{name = Name, output_handle = Handle,
                 role = Role, source = S, target = T},

    % stash the From pid
    State#state{links = Links#{Handle => Link},
                next_link_handle = Handle + 1,
                pending_attach_requests = PARs#{Name => From},
                link_index = LinkIndex#{Name => Handle}}.

unpack(undefined) -> undefined;
unpack({_, V}) -> V.

pack_uint(Int) -> {uint, Int}.

-spec find_link_by_input_handle(link_handle(), #state{}) ->
    {ok, #link{}} | not_found.
find_link_by_input_handle(InHandle, #state{link_handle_index = LHI,
                                           links = Links}) ->
    case LHI of
        #{InHandle := OutHandle} ->
            case Links of
                #{OutHandle := Link} ->
                    {ok, Link};
                _ -> not_found
            end;
        _ -> not_found
    end.
