-module (lock_serv).

-behaviour (gen_server).

-export([start_link/0, terminate/2, handle_info/2, code_change/3]).
-export([lock/1, lock/2, unlock/1, unlock_all/0]).
-export([init/1, handle_call/3, handle_cast/2]).

-record(lock_state, {
    % Currently held locks (key -> pid)
    locks=dict:new(),
    % Current clients waiting for lock (key -> queue<pid>)
    waiters=dict:new(),
    % Current locks held by clients (pid -> list<key)
    clients=dict:new()
    }).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

terminate(shutdown, State) ->
    {ok, State}.

handle_info({'EXIT', Pid, Reason}, State) ->
    error_logger:info_msg("Got an exit from ~p: ~p~n", [Pid, Reason]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    error_logger:info_msg("Code's changing.  Hope that's OK~n", []),
    {ok, State}.

lock(Key) ->
    gen_server:call(?MODULE, {lock, Key}).

lock(Key, WaitMillis) ->
    % Don't wait longer than erlang allows me to.
    Wait = lists:min([WaitMillis, 16#ffffffff]),
    case gen_server:call(?MODULE, {lock, Key, Wait}) of
        ok -> ok;
        delayed ->
            receive
                {acquiring, Key, From} ->
                    From ! {ack, self()},
                    receive {acquired, Key} -> ok end
                after Wait -> locked
            end
    end.

unlock(Key) ->
    gen_server:call(?MODULE, {unlock, Key}).

unlock_all() ->
    gen_server:cast(?MODULE, {unlock_all, self()}).

init(_Args) ->
    {ok, #lock_state{}}.

handle_call({lock, Key}, From, Locks) ->
    {Response, Locks2} = lock(Key, From, Locks),
    {reply, Response, Locks2};
handle_call({lock, Key, Wait}, From, Locks) ->
    {Response, Locks2} = lock(Key, Wait, From, Locks),
    {reply, Response, Locks2};
handle_call({unlock, Key}, From, Locks) ->
    {Response, Locks2} = unlock(Key, From, Locks),
    {reply, Response, Locks2}.

handle_cast(reset, _Locks) ->
    error_logger:info_msg("Someone casted a reset", []),
   {noreply, #lock_state{}};
handle_cast({unlock_all, Pid}, Locks) ->
   error_logger:info_msg("Unlocking all owned by ~p", [Pid]),
  {noreply, unlock_all(Pid, Locks)}.
  

% Actual lock handling

lock(Key, {From, _Something}, Locks) ->
    case dict:find(Key, Locks#lock_state.locks) of
        {ok, From} -> {ok, Locks};
        {ok, _Key} -> {locked, Locks};
        error -> {ok, unconditional_lock(Key, From, Locks)}
    end.

lock(Key, Wait, {From, Something}, Locks) ->
    case lock(Key, {From, Something}, Locks) of
        {ok, Rv} -> {ok, Rv};
        _ -> {delayed, enqueue_waiter(Key, Wait, From, Locks)}
    end.

unlock(Key, {From, _Something}, Locks) ->
    case dict:find(Key, Locks#lock_state.locks) of
        {ok, From} ->
            {ok, hand_over_lock(Key, From, Locks)};
        {ok, _Someone} -> {not_yours, Locks};
        _ -> {not_locked, Locks}
    end.

unlock_all(Pid, LocksIn) ->
    lists:foldl(fun(K, Locks) -> hand_over_lock(K, Pid, Locks) end,
        LocksIn, get_client_list(Pid, LocksIn#lock_state.clients)).

% Private support stuff

get_client_list(From, D) ->
    case dict:find(From, D) of
        {ok, V} -> V;
        error -> []
    end.

add_client(Key, From, D) ->
    dict:store(From, get_client_list(From, D) ++ [Key], D).

remove_client(Key, From, D) ->
    case get_client_list(From, D) of
        [] -> D;
        [Key] -> dict:erase(From, D);
        L -> dict:store(From, lists:delete(Key, L), D)
    end.

% Reserve the lock
unconditional_lock(Key, From, Locks) ->
    Locks#lock_state{
        locks=dict:store(Key, From, Locks#lock_state.locks),
        clients=add_client(Key, From, Locks#lock_state.clients)}.

% return the specified lock.  If someone else wants it, give it up
hand_over_lock(Key, From, Locks) ->
    case dict:find(Key, Locks#lock_state.waiters) of
        {ok, Q} ->
            try_waiter(Key, From, Q, Locks);
        error ->
            Locks#lock_state{
                locks=dict:erase(Key, Locks#lock_state.locks),
                clients=remove_client(Key, From, Locks#lock_state.clients)}
    end.

try_waiter(Key, From, Q, Locks) ->
    case queue:is_empty(Q) of
    true ->
        Locks#lock_state{
            locks=dict:erase(Key, Locks#lock_state.locks),
            clients=remove_client(Key, From, Locks#lock_state.clients)};
    _ ->
        {{value, Waiter}, Q2} = queue:out(Q),
        Waiter ! {acquiring, Key, self()},
        receive
            {ack, Waiter} ->
                Waiter ! {acquired, Key},
                unconditional_lock(Key, Waiter,
                    Locks#lock_state{
                        waiters=dict:store(Key, Q2, Locks#lock_state.waiters)});
            _ -> try_waiter(Key, From, Q2, Locks)
            after 25 ->
                try_waiter(Key, From, Q2, Locks)
        end
    end.

% I may want to have this thing magically time out after a while.
enqueue_waiter(Key, _Wait, From, Locks) ->
    Q = case dict:find(Key, Locks#lock_state.waiters) of
        {ok, Queue} -> Queue;
        error -> queue:new()
    end,
    Locks#lock_state{waiters=dict:store(
        Key, queue:in(From, Q), Locks#lock_state.waiters)}.