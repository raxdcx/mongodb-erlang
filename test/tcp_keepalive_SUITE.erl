-module(tcp_keepalive_SUITE).

-include_lib("proper/include/proper.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-compile([export_all, nowarn_export_all]).

%%====================================================================
%% CT Callbacks
%%====================================================================

all() ->
  [
    prop_keepalive_nodelay_enabled,
    prop_existing_options_preserved,
    prop_ssl_user_option_override,
    unit_keepalive_concrete,
    unit_keepalive_ping
  ].

init_per_suite(Config) ->
  application:ensure_all_started(mongodb),
  [{database, <<"test">>} | Config].

end_per_suite(_Config) ->
  ok.

%%====================================================================
%% Property Tests
%%====================================================================
prop_keepalive_nodelay_enabled(Config) ->
  Database = ?config(database, Config),

  Property = ?FORALL(Timeout, range(1000, 30000),
    begin
      try
        {ok, Conn} = mc_worker_api:connect([{database, Database}, {timeout, Timeout}]),

        %% Extract socket from mc_worker gen_server state
        WorkerState = sys:get_state(Conn),
        Socket = element(2, WorkerState),

        %% Query socket options for keepalive and nodelay
        {ok, Opts} = inet:getopts(Socket, [keepalive, nodelay]),

        mc_worker_api:disconnect(Conn),

        %% Assert both keepalive and nodelay are true
        lists:member({keepalive, true}, Opts) andalso
        lists:member({nodelay, true}, Opts)
      catch
        Class:Error:Stack ->
          ct:log("Property 1 failed: ~p:~p~n~p", [Class, Error, Stack]),
          false
      end
    end),

  true = proper:quickcheck(Property, [{numtests, 100}, {to_file, user}]),
  ok.

prop_existing_options_preserved(Config) ->
  Database = ?config(database, Config),

  Property = ?FORALL(Timeout, range(1000, 30000),
    begin
      try
        {ok, Conn} = mc_worker_api:connect([{database, Database}, {timeout, Timeout}]),

        %% Extract socket from mc_worker gen_server state
        WorkerState = sys:get_state(Conn),
        Socket = element(2, WorkerState),

        %% Query socket options for active and packet
        {ok, Opts} = inet:getopts(Socket, [active, packet]),

        mc_worker_api:disconnect(Conn),

        %% Assert existing options are preserved alongside keepalive/nodelay
        %% Note: inet:getopts returns {packet, 0} which is equivalent to {packet, raw}
        lists:member({active, true}, Opts) andalso
        lists:member({packet, 0}, Opts)
      catch
        Class:Error:Stack ->
          ct:log("Property 2 failed: ~p:~p~n~p", [Class, Error, Stack]),
          false
      end
    end),

  true = proper:quickcheck(Property, [{numtests, 100}, {to_file, user}]),
  ok.

prop_ssl_user_option_override(_Config) ->
  %% Skip if SSL MongoDB is not available
  try mc_worker_api:connect([{database, <<"test">>}, {ssl, true},
                             {ssl_opts, [{verify, verify_none}]}]) of
    {ok, TestConn} ->
      mc_worker_api:disconnect(TestConn),
      run_ssl_override_property();
    {error, _} ->
      {skip, "SSL-enabled MongoDB not available"}
  catch
    _:_ ->
      {skip, "SSL-enabled MongoDB not available"}
  end.

run_ssl_override_property() ->
  Property = ?FORALL({Keepalive, Nodelay}, {boolean(), boolean()},
    begin
      try
        SslOpts = [{verify, verify_none},
                   {keepalive, Keepalive},
                   {nodelay, Nodelay}],
        {ok, Conn} = mc_worker_api:connect([{database, <<"test">>},
                                            {ssl, true},
                                            {ssl_opts, SslOpts}]),

        %% Extract SSL socket from mc_worker gen_server state
        WorkerState = sys:get_state(Conn),
        Socket = element(2, WorkerState),

        %% For SSL sockets, use ssl:getopts/2
        {ok, Opts} = ssl:getopts(Socket, [keepalive, nodelay]),

        mc_worker_api:disconnect(Conn),

        %% Assert user-provided values take precedence over defaults
        lists:member({keepalive, Keepalive}, Opts) andalso
        lists:member({nodelay, Nodelay}, Opts)
      catch
        Class:Error:Stack ->
          ct:log("Property 3 failed: ~p:~p~n~p", [Class, Error, Stack]),
          false
      end
    end),

  true = proper:quickcheck(Property, [{numtests, 100}, {to_file, user}]),
  ok.


%%====================================================================
%% Unit Tests
%%====================================================================
unit_keepalive_concrete(Config) ->
  Database = ?config(database, Config),
  {ok, Conn} = mc_worker_api:connect([{database, Database}]),

  %% Extract socket from mc_worker gen_server state
  WorkerState = sys:get_state(Conn),
  Socket = element(2, WorkerState),

  %% Query socket options
  {ok, Opts} = inet:getopts(Socket, [keepalive, nodelay]),

  %% Assert keepalive and nodelay are both true
  ?assert(lists:member({keepalive, true}, Opts)),
  ?assert(lists:member({nodelay, true}, Opts)),

  mc_worker_api:disconnect(Conn),
  ok.

%% Integration sanity check: connection with keepalive can execute a ping command
%% Validates: Requirements 1.1, 1.2, 5.1, 5.2
unit_keepalive_ping(Config) ->
  Database = ?config(database, Config),
  {ok, Conn} = mc_worker_api:connect([{database, Database}]),

  %% Execute ping command
  Result = mc_worker_api:command(Conn, bson:document([{ping, 1}])),
  ?assertEqual({true, #{<<"ok">> => 1.0}}, Result),

  mc_worker_api:disconnect(Conn),
  ok.
