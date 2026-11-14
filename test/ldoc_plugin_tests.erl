-module(ldoc_plugin_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/file.hrl").

real_provider_generation_test_() ->
    {timeout, 240, fun real_provider_generation/0}.

real_provider_generation() ->
    Workspace = filename:join(["/private/tmp", "ldoc-plugin-tests-" ++
                                integer_to_list(erlang:unique_integer([positive]))]),
    Root = filename:join(Workspace, "consumer"),
    try
        ok = filelib:ensure_dir(filename:join(Root, "src/placeholder")),
        SourceRoot = filename:dirname(filename:dirname(filename:absname(?FILE))),
        Rebar = os:find_executable("rebar3"),
        ?assert(Rebar =/= false),
        Git = os:find_executable("git"),
        ?assert(Git =/= false),
        {ok, Revision} = command(Git, ["rev-parse", "HEAD"], SourceRoot),
        Plugin = "{ldoc, {git, \"file://" ++ SourceRoot ++
                 "\", {ref, \"" ++ string:trim(binary_to_list(Revision)) ++ "\"}}}",
        Config = "{project_plugins, [" ++ Plugin ++ "]}.\n",
        ok = file:write_file(filename:join(Root, "rebar.config"), Config),
        create_consumer(Root, "Initial provider documentation."),
        {ok, Help} = command(Rebar, ["help", "ldoc"], Root),
        ?assertNotEqual(nomatch, binary:match(Help, <<"--source-base">>)),
        {ok, _} = command(Rebar, ["ldoc"], Root),
        Container = filename:join([Root, "_build", "default", "ldoc"]),
        Current = filename:join(Container, "current"),
        {ok, FirstTarget} = file:read_link(Current),
        FirstRef = filename:join([Container, FirstTarget]),
        FirstTree = tree(FirstRef),
        ?assert(tree_contains(FirstRef, <<"Initial provider documentation">>)),
        create_consumer(Root, "Updated provider documentation with additional words."),
        {ok, _} = command(Rebar, ["ldoc"], Root),
        {ok, SecondTarget} = file:read_link(Current),
        ?assertNotEqual(FirstTarget, SecondTarget),
        ?assertEqual(FirstTree, tree(FirstRef)),
        SecondRef = filename:join([Container, SecondTarget]),
        ?assertEqual(true, tree_contains(SecondRef,
                                         <<"Updated provider documentation">>)),
        {ok, GenerationBeforeFailure} = file:read_link(Current),
        GoodTree = tree(filename:join([Container, GenerationBeforeFailure])),
        ok = file:write_file(filename:join([Root, "src", "plugin_fixture.erl"]),
                             <<"-module(plugin_fixture).\nbroken( ->.\n">>),
        bump_mtime(filename:join([Root, "src", "plugin_fixture.erl"])),
        ?assertMatch({error, _}, command(Rebar, ["ldoc"], Root)),
        ?assertEqual({ok, GenerationBeforeFailure}, file:read_link(Current)),
        ?assertEqual(GoodTree,
                     tree(filename:join([Container, GenerationBeforeFailure]))),
        create_consumer(Root, "Pipeline failure baseline."),
        ok = file:write_file(filename:join([Root, "src", "plugin_fixture.erl"]),
            <<"%% @doc <broken\n-module(plugin_fixture).\n-export([answer/0]).\n"
              "%% @doc <broken\nanswer() -> 42.\n">>),
        bump_mtime(filename:join([Root, "src", "plugin_fixture.erl"])),
        ?assertMatch({error, _}, command(Rebar, ["ldoc"], Root)),
        ?assertEqual({ok, GenerationBeforeFailure}, file:read_link(Current)),
        ?assertEqual(GoodTree,
                     tree(filename:join([Container, GenerationBeforeFailure]))),
        ok = file:delete(filename:join([Root, "src", "plugin_fixture.erl"])),
        stale_lock_is_preserved(Rebar, Root, Container, Current, GenerationBeforeFailure),
        unowned_container_is_preserved(Rebar, Root)
    after
        remove_tree(Workspace)
    end.

create_consumer(Root, FunctionDoc) ->
    App = filename:join([Root, "src", "plugin_fixture.app.src"]),
    Source = filename:join([Root, "src", "plugin_fixture.erl"]),
    ok = file:write_file(App,
        <<"{application, plugin_fixture, [{description, \"Fixture\"}, {vsn, \"1.0.0\"}, "
          "{applications, [kernel, stdlib]}, {modules, [plugin_fixture]}]}.\n">>),
    ok = file:write_file(Source, iolist_to_binary([
        "-module(plugin_fixture).\n-moduledoc \"Plugin fixture module.\".\n",
        "-export([answer/0]).\n-doc \"", FunctionDoc, "\".\nanswer() -> 42.\n"])),
    bump_mtime(Source).

stale_lock_is_preserved(Rebar, Root, Container, Current, ExpectedTarget) ->
    Lock = filename:join(Container, ".ldoc-lock"),
    ok = file:write_file(Lock, <<"stale-owner\n">>, [binary, exclusive]),
    ?assertMatch({error, _}, command(Rebar, ["ldoc"], Root)),
    ?assertEqual({ok, ExpectedTarget}, file:read_link(Current)),
    ?assertEqual({ok, <<"stale-owner\n">>}, file:read_file(Lock)),
    ok = file:delete(Lock).

unowned_container_is_preserved(Rebar, Root) ->
    OtherRoot = filename:join(filename:dirname(Root), "unowned-consumer"),
    ok = filelib:ensure_dir(filename:join(OtherRoot, "src/placeholder")),
    {ok, Config} = file:read_file(filename:join(Root, "rebar.config")),
    ok = file:write_file(filename:join(OtherRoot, "rebar.config"), Config),
    create_consumer(OtherRoot, "Unowned fixture."),
    Container = filename:join([OtherRoot, "_build", "default", "ldoc"]),
    ok = filelib:ensure_dir(filename:join([Container, "keep", "sentinel"])),
    Sentinel = filename:join([Container, "keep", "sentinel"]),
    ok = file:write_file(Sentinel, <<"user data">>),
    ?assertMatch({error, _}, command(Rebar, ["ldoc"], OtherRoot)),
    ?assertEqual({ok, <<"user data">>}, file:read_file(Sentinel)).

command(Executable, Args, Cwd) ->
    Port = open_port({spawn_executable, Executable},
        [binary, exit_status, use_stdio, stderr_to_stdout,
         {args, Args}, {cd, Cwd}, {line, 4096}]),
    collect(Port, []).

collect(Port, Acc) ->
    receive
        {Port, {data, {eol, Data}}} -> collect(Port, [<<Data/binary, "\n">> | Acc]);
        {Port, {data, {noeol, Data}}} -> collect(Port, [Data | Acc]);
        {Port, {exit_status, 0}} -> {ok, iolist_to_binary(lists:reverse(Acc))};
        {Port, {exit_status, Status}} ->
            {error, {Status, iolist_to_binary(lists:reverse(Acc))}}
    end.

tree(Root) ->
    tree_dir(Root, "").

tree_contains(Root, Bytes) ->
    lists:any(fun({_Name, Value}) -> is_binary(Value) andalso
                                    binary:match(Value, Bytes) =/= nomatch
              end, tree(Root)).

tree_dir(Root, Prefix) ->
    {ok, Names} = file:list_dir(Root),
    lists:sort(lists:append([tree_path(Root, Name, Prefix) || Name <- Names])).

tree_path(Root, Name, Prefix) ->
    Path = filename:join(Root, Name),
    Rel = case Prefix of
        "" -> Name;
        _ -> filename:join(Prefix, Name)
    end,
    case file:read_link_info(Path) of
        {ok, #file_info{type = directory}} ->
            [{Rel, directory} | tree_dir(Path, Rel)];
        {ok, #file_info{type = regular}} -> [{Rel, read(Path)}];
        {ok, #file_info{type = symlink}} -> [{Rel, link_target(Path)}]
    end.
read(Path) -> {ok, Bytes} = file:read_file(Path), Bytes.
link_target(Path) -> {ok, Target} = file:read_link(Path), Target.

bump_mtime(Path) ->
    {ok, Info} = file:read_file_info(Path),
    Seconds = calendar:datetime_to_gregorian_seconds(Info#file_info.mtime) + 60,
    NewTime = calendar:gregorian_seconds_to_datetime(Seconds),
    file:write_file_info(Path, Info#file_info{mtime = NewTime}).

remove_tree(Path) ->
    case file:read_link_info(Path) of
        {ok, #file_info{type = directory}} ->
            {ok, Names} = file:list_dir(Path),
            lists:foreach(fun(Name) -> remove_tree(filename:join(Path, Name)) end, Names),
            file:del_dir(Path);
        {ok, #file_info{type = symlink}} -> file:delete(Path);
        {ok, #file_info{type = regular}} -> file:delete(Path);
        {error, enoent} -> ok
    end.
