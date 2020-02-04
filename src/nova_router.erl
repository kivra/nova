%%%-------------------------------------------------------------------
%%% @author Niclas Axelsson <niclas@burbas.se>
%%% @copyright (C) 2019, Niclas Axelsson
%%% @doc
%%%
%%% @end
%%% Created : 17 Nov 2019 by Niclas Axelsson <niclas@burbas.se>
%%%-------------------------------------------------------------------
-module(nova_router).

-behaviour(gen_server).

%% API
-export([
         start_link/0,
         process_routefile/1,
         status_page/2,
         add_route/2,
         get_all_routes/0,
         apply_routes/0
        ]).

%% gen_server callbacks
-export([
         init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3,
         format_status/2
        ]).

-include_lib("nova/include/nova.hrl").

-define(SERVER, ?MODULE).
-define(STATIC_ROUTE_TABLE, static_route_table).

-record(state, {
                route_table :: [{binary(), list()}] | [],
                static_route_table :: #{StatusCode :: integer() => {Mod :: atom(), Func :: atom()}}
               }).

-type route_info() :: #{application := atom(),
                        prefix := atom(),
                        host := atom() | string(),
                        security := false | {atom(), atom()},
                        _ => _}.
-export_type([route_info/0]).

-type route() :: {Route :: string(), {Module :: atom(), Function :: atom()}} |
                 {Route :: string(), {Module :: atom(), Function :: atom()}, Options :: map()} |
                 {Route :: string(), Module :: atom(), Function :: atom()} |
                 {Route :: string(), CallbackInfo :: atom(), Options :: map()} |
                 {StatusCode :: integer(), {Module :: atom(), Function :: atom()}} |
                 {Route :: string(), Filename :: string()}.
-export_type([route/0]).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%% @end
%%--------------------------------------------------------------------
-spec start_link() -> {ok, Pid :: pid()} |
                      {error, Error :: {already_started, pid()}} |
                      {error, Error :: term()} |
                      ignore.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%--------------------------------------------------------------------
%% @doc
%% Checks if there is a route for a special "status page" in the route
%% table. This is done outside of cowboy since they does not support having
%% custom pages for status pages (Eg 404)
%% @end
%%--------------------------------------------------------------------
-spec status_page(Status :: integer(), Req :: cowboy_req:req()) ->
                         {ok, StatusCode :: integer(), Headers :: cowboy:http_headers(), Body :: binary(), State0 :: nova_http_handler:nova_http_state()} | {error, not_found}.
status_page(Status, Req) when is_integer(Status) ->
    gen_server:call(?SERVER, {fetch_status_page, Status, Req}).


%%--------------------------------------------------------------------
%% @doc
%% Add a route to nova.
%% @end
%%--------------------------------------------------------------------
-spec add_route(RouteInfo :: route_info(), Route :: route()) -> ok.
add_route(RouteInfo, Route = {_, FileOrDir}) when is_list(FileOrDir) ->
    gen_server:cast(?SERVER, {add_static, RouteInfo, Route});
add_route(RouteInfo, Route) ->
    gen_server:cast(?SERVER, {add_route, RouteInfo, Route}).


%%--------------------------------------------------------------------
%% @doc
%% Returns all the routes for this node. The RouteTable contains all
%% routes injected into cowboy while the StaticRouteTable contains
%% route information about status pages (eg 404).
%% @end
%%--------------------------------------------------------------------
-spec get_all_routes() -> {ok, {RouteTable :: list(), StaticRouteTable :: map()}}.
get_all_routes() ->
    gen_server:call(?SERVER, get_all_routes).
%%--------------------------------------------------------------------
%% @doc
%% Process the routefile for the specified application and injects the
%% resulting route-table into cowboy.
%% TODO! We need this to work in a recursive manner.
%% @end
%%--------------------------------------------------------------------
-spec process_routefile(#{name := atom(), routes_file => list()}) -> ok.
process_routefile(#{name := Application, routes_file := RouteFile}) ->
    case code:lib_dir(Application) of
        {error, bad_name} ->
            ?WARNING("Could not find the application ~p. Check your config and rerun the application", [Application]),
            ok;
        Filepath ->
            ?DEBUG("Processing routefile: ~p", [Filepath]),
            RouteFilePath = filename:join([Filepath, RouteFile]),
            {ok, AppRoutes} = file:consult(RouteFilePath),
            lists:foreach(fun(AppMap) ->
                                  %% Extract information
                                  Prefix = maps:get(prefix, AppMap, ""),
                                  Host = maps:get(host, AppMap, '_'),
                                  Routes = maps:get(routes, AppMap, []),
                                  Statics = maps:get(statics, AppMap, []),
                                  Secure = maps:get(security, AppMap, false),
                                  %% Built intermediate object
                                  RouteInfo = #{application => Application,
                                                prefix => Prefix,
                                                host => Host,
                                                security => Secure},
                                  %% Add routes
                                  [ add_route(RouteInfo, Route) || Route <- Routes ++ Statics ]
                          end, AppRoutes)
    end;
process_routefile(AppInfo = #{name := Application}) ->
    Routename = lists:concat(["priv/", Application, ".routes.erl"]),
    process_routefile(AppInfo#{routes_file => Routename}).

%%--------------------------------------------------------------------
%% @doc
%% Takes all the routes in nova_router and applies them in cowboy_router.
%% The changes should be instant.
%% @end
%%--------------------------------------------------------------------
-spec apply_routes() -> ok.
apply_routes() ->
    gen_server:cast(?SERVER, apply_routes).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%% @end
%%--------------------------------------------------------------------
-spec init(Args :: term()) -> {ok, State :: term()} |
                              {ok, State :: term(), Timeout :: timeout()} |
                              {ok, State :: term(), hibernate} |
                              {stop, Reason :: term()} |
                              ignore.
init([]) ->
    process_flag(trap_exit, true),
    {ok, MainApplication} = application:get_application(),
    Apps = application:get_env(nova_applications, MainApplication, []),
    ?DEBUG("Bootstrapping router for application ~p, included_apps: ~p", [MainApplication, Apps]),
    [ process_routefile(#{name => NovaApp}) || NovaApp <- [MainApplication|Apps] ],
    apply_routes(),
    {ok, #state{
            route_table = [],
            static_route_table = #{}
           }}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%% @end
%%--------------------------------------------------------------------
-spec handle_call(Request :: term() | {fetch_status_page, Status :: integer(), Req :: cowboy_req:req()},
                  From :: {pid(), term()}, State :: term()) ->
                         {reply, Reply :: term(), NewState :: term()} |
                         {reply, Reply :: term(), NewState :: term(), Timeout :: timeout()} |
                         {reply, Reply :: term(), NewState :: term(), hibernate} |
                         {noreply, NewState :: term()} |
                         {noreply, NewState :: term(), Timeout :: timeout()} |
                         {noreply, NewState :: term(), hibernate} |
                         {stop, Reason :: term(), Reply :: term(), NewState :: term()} |
                         {stop, Reason :: term(), NewState :: term()}.
handle_call({fetch_status_page, Status, Req}, _From,
            State = #state{static_route_table = StaticRouteTable}) ->
    case maps:get(Status, StaticRouteTable, undefined) of
        {Mod, Func} ->
            Reply = nova_http_handler:handle(Mod, Func, Req, #{mod => dummy,
                                                               func => dummy,
                                                               methods => '_'}),
            {reply, Reply, State};
        _ ->
            {reply, {error, not_found}, State}
    end;
handle_call(get_all_routes, _From, State = #state{route_table = RoutesTable,
                                                  static_route_table = StaticRouteTable}) ->
    {reply, {ok, {RoutesTable, StaticRouteTable}}, State};
handle_call(Request, _From, State) ->
    ?WARNING("Unknown request: ~p when state: ~p", [Request, State]),
    {reply, error, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%% @end
%%--------------------------------------------------------------------
-spec handle_cast(Request :: term(), State :: term()) ->
                         {noreply, NewState :: term()} |
                         {noreply, NewState :: term(), Timeout :: timeout()} |
                         {noreply, NewState :: term(), hibernate} |
                         {stop, Reason :: term(), NewState :: term()}.
handle_cast({add_static, #{application := Application, prefix := Prefix,
                           host := Host, security := _Security}, RouteDetails = {Route, DirOrFile}},
            State = #state{route_table = RouteTable}) ->
    case code:lib_dir(Application, priv) of
        {error, _} ->
            ?ERROR("Could not apply route ~p. Could not find priv dir of application ~p", [RouteDetails, Application]),
            {noreply, State};
        PrivDir ->
            CowboyRoute =
                case filelib:is_dir(filename:join([PrivDir, DirOrFile])) of
                    true ->
                        {Prefix++Route, cowboy_static, {priv_dir, Application, DirOrFile}};
                    _ ->
                        case filelib:is_file(filename:join([PrivDir, DirOrFile])) of
                            true ->
                                {Prefix++Route, cowboy_static, {priv_file, Application, DirOrFile}};
                            _ ->
                                ?WARNING("Could not find the static file ~p which is reffered from the route ~p. Ignoring route", [DirOrFile, RouteDetails]),
                                false
                        end
                end,
            case CowboyRoute of
                false ->
                    {noreply, State};
                _ ->
                    NewRouteTable = prop_upsert(Host, CowboyRoute, RouteTable),
                    {noreply, State#state{route_table = NewRouteTable}}
            end
    end;
handle_cast({add_route, _, {StatusCode, {Module, Function}}},
            State = #state{static_route_table = StaticRouteTable}) when is_integer(StatusCode) ->
    %% Do something with the status code
    StaticRouteTable2 = maps:put(StatusCode, {Module, Function}, StaticRouteTable),
    ?DEBUG("Applying status-route for code ~p, MF: ~p", [StatusCode, {Module, Function}]),
    {noreply, State#state{static_route_table = StaticRouteTable2}};
handle_cast({add_route, #{application := Application, prefix := Prefix,
                          host := Host, security := Security}, RouteDetails},
            State = #state{route_table = RouteTable}) ->
    InitialState = #{app => Application,
                     secure => Security},
    CowboyRoute =
        case RouteDetails of
            {Route, {Module, Function}} ->
                {Prefix++Route,
                 nova_http_handler,
                 InitialState#{mod => Module,
                               func => Function,
                               methods => '_',
                               nova_handler => nova_http_handler}};
            {Route, CallbackInfo, Options = #{protocol := ws}} ->
                {Prefix++Route,
                 nova_ws_handler,
                 InitialState#{mod => CallbackInfo,
                               subprotocols => maps:get(subprotocols, Options, []),
                               nova_handler => nova_ws_handler}};
            {Route, {Module, Function}, Options} ->
                {Prefix++Route,
                 nova_http_handler,
                 InitialState#{mod => Module,
                               func => Function,
                               methods => get_methods(Options),
                               nova_handler => nova_http_handler}};
            {Route, Module, Function} ->
                %% This is to keep legacy-format. Should be deprecated
                ?DEPRECATION("Route of format {Route, Module, Function} is deprecated and will be removed in future versions of Nova"),
                {Prefix++Route,
                 nova_http_handler,
                 InitialState#{mod => Module,
                               func => Function,
                               methods => '_',
                               nova_handler => nova_http_handler}};
            Other ->
                ?WARNING("Could not parse route ~p", [Other]),
                erlang:throw({route_error, Other})
        end,
    ?DEBUG("Applying route: ~p", [RouteDetails]),
    NewRouteTable = prop_upsert(Host, CowboyRoute, RouteTable),
    {noreply, State#state{route_table = NewRouteTable}};
handle_cast(apply_routes, State = #state{route_table = RouteTable}) ->
    Dispatch = cowboy_router:compile(RouteTable),
    cowboy:set_env(nova_listener, dispatch, Dispatch),
    {noreply, State};
handle_cast(Request, State) ->
    ?WARNING("Got unknown cast in router: ~p", [Request]),
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%% @end
%%--------------------------------------------------------------------
-spec handle_info(Info :: timeout() | term(), State :: term()) ->
                         {noreply, NewState :: term()} |
                         {noreply, NewState :: term(), Timeout :: timeout()} |
                         {noreply, NewState :: term(), hibernate} |
                         {stop, Reason :: normal | term(), NewState :: term()}.
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%% @end
%%--------------------------------------------------------------------
-spec terminate(Reason :: normal | shutdown | {shutdown, term()} | term(),
                State :: term()) -> any().
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%% @end
%%--------------------------------------------------------------------
-spec code_change(OldVsn :: term() | {down, term()},
                  State :: term(),
                  Extra :: term()) -> {ok, NewState :: term()} |
                                      {error, Reason :: term()}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called for changing the form and appearance
%% of gen_server status when it is returned from sys:get_status/1,2
%% or when it appears in termination error logs.
%% @end
%%--------------------------------------------------------------------
-spec format_status(Opt :: normal | terminate,
                    Status :: list()) -> Status :: term().
format_status(_Opt, Status) ->
    Status.

%%%===================================================================
%%% Internal functions
%%%===================================================================
get_methods(#{methods := M}) when is_list(M) ->
    Res = lists:map(fun(get)  -> <<"GET">>;
                       (post) -> <<"POST">>;
                       (put) -> <<"PUT">>;
                       (delete) -> <<"DELETE">>;
                       (_) -> throw(unknown_method)
                    end, M),
    case length(Res) of
        4 -> '_';
        _ -> Res
    end;
get_methods(#{methods := M}) ->
    get_methods(#{methods => [M]});
get_methods(_) ->
    '_'.


prop_upsert(Key, NewEntry, Proplist) ->
    case proplists:lookup(Key, Proplist) of
        none ->
            [{Key, [NewEntry]}|Proplist];
        {Key, OldList} ->
            [{Key, [NewEntry|OldList]}|proplists:delete(Key, Proplist)]
    end.
