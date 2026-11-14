-module(ldoc_plugin_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/file.hrl").

real_provider_generation_test_() ->
    {timeout, 240, fun real_provider_generation/0}.

real_provider_generation() ->
    TempBase = case os:getenv("TMPDIR") of
        false -> "/tmp";
        "" -> "/tmp";
        Path -> Path
    end,
    Workspace = filename:join([TempBase, "ldoc-plugin-tests-" ++
                                integer_to_list(erlang:unique_integer([positive]))]),
    Root = filename:join(Workspace, "consumer"),
    try
        ok = filelib:ensure_dir(filename:join(Root, "src/placeholder")),
        SourceRoot = filename:dirname(filename:dirname(filename:absname(?FILE))),
        Rebar = os:find_executable("rebar3"),
        ?assert(Rebar =/= false),
        Git = os:find_executable("git"),
        ?assert(Git =/= false),
        PluginSource = filename:join(Workspace, "plugin-source"),
        ok = make_plugin_source(Git, SourceRoot, PluginSource),
        Plugin = "{ldoc, {git, \"file://" ++ PluginSource ++
                 "\", {branch, \"main\"}}}",
        Config = "{project_plugins, [" ++ Plugin ++ "]}.\n",
        ok = file:write_file(filename:join(Root, "rebar.config"), Config),
        create_consumer(Root, "Initial provider documentation."),
        {ok, Help} = command(Rebar, ["help", "ldoc"], Root),
        ?assertNotEqual(nomatch, binary:match(Help, <<"--source-base">>)),
        {ok, FirstOutput} = command(Rebar, ["ldoc"], Root),
        Container = filename:join([Root, "_build", "default", "ldoc"]),
        Current = filename:join(Container, "current"),
        {ok, FirstTarget} = file:read_link(Current),
        FirstRef = filename:join([Container, FirstTarget]),
        ?assertNotEqual(nomatch, binary:match(FirstOutput, <<"current/site/index.html">>)),
        FirstTree = tree(FirstRef),
        ?assert(site_contains(FirstRef, <<"Initial provider documentation">>)),
        nonregular_generation_marker_is_refused(Rebar, Root, Container,
                                                Current, FirstTarget, FirstRef, FirstTree),
        create_consumer(Root, "Updated provider documentation with additional words."),
        {ok, _} = command(Rebar, ["ldoc"], Root),
        {ok, SecondTarget} = file:read_link(Current),
        ?assertNotEqual(FirstTarget, SecondTarget),
        ?assertEqual(FirstTree, tree(FirstRef)),
        SecondRef = filename:join([Container, SecondTarget]),
        ?assert(site_contains(SecondRef, <<"Updated provider documentation">>)),
        ExplicitOutput = filename:join(Workspace, "explicit-output"),
        {ok, _} = command(Rebar, ["ldoc", "--output", ExplicitOutput], Root),
        ?assert(filelib:is_regular(filename:join([ExplicitOutput, "site", "index.html"]))),
        ?assertMatch({error, _}, command(Rebar, ["ldoc", "--output", ExplicitOutput], Root)),
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
        invalid_current_is_preserved(Rebar, Root, Workspace, Current),
        unowned_container_is_preserved(Rebar, Root),
        symlink_container_is_preserved(Rebar, Root),
        symlink_build_ancestor_is_refused(Rebar, Root, Workspace)
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

nonregular_generation_marker_is_refused(Rebar, Root, Container, Current,
                                         Target, Reference, ReferenceTree) ->
    Mkfifo = os:find_executable("mkfifo"),
    ?assert(Mkfifo =/= false),
    Marker = filename:join([Container, filename:dirname(Target), ".ldoc-generation"]),
    ok = file:delete(Marker),
    {ok, _} = command(Mkfifo, [Marker], Root),
    Started = erlang:monotonic_time(millisecond),
    Result = command(Rebar, ["ldoc"], Root),
    Elapsed = erlang:monotonic_time(millisecond) - Started,
    ?assertMatch({error, _}, Result),
    ?assert(Elapsed < 10000),
    ?assertEqual({ok, Target}, file:read_link(Current)),
    ?assertEqual(ReferenceTree, tree(Reference)),
    ok = file:delete(Marker),
    ok = file:write_file(Marker, <<"ldoc-rebar3-generation-v1\n">>, [binary, exclusive]),
    ok.

invalid_current_is_preserved(Rebar, Root, Workspace, Current) ->
    Outside = filename:join(Workspace, "outside-target"),
    ok = file:write_file(Outside, <<"outside bytes">>),
    ok = file:delete(Current),
    ok = file:make_symlink(Outside, Current),
    ?assertMatch({error, _}, command(Rebar, ["ldoc"], Root)),
    ?assertEqual({ok, Outside}, file:read_link(Current)),
    ?assertEqual({ok, <<"outside bytes">>}, file:read_file(Outside)).

symlink_container_is_preserved(Rebar, Root) ->
    OtherRoot = filename:join(filename:dirname(Root), "symlink-consumer"),
    ok = filelib:ensure_dir(filename:join(OtherRoot, "src/placeholder")),
    {ok, Config} = file:read_file(filename:join(Root, "rebar.config")),
    ok = file:write_file(filename:join(OtherRoot, "rebar.config"), Config),
    create_consumer(OtherRoot, "Symlink fixture."),
    BuildDefault = filename:join([OtherRoot, "_build", "default"]),
    ok = filelib:ensure_dir(filename:join(BuildDefault, "placeholder")),
    Container = filename:join(BuildDefault, "ldoc"),
    External = filename:join(filename:dirname(Root), "external-container"),
    ok = filelib:ensure_dir(filename:join(External, "sentinel/keep")),
    Sentinel = filename:join([External, "sentinel", "keep"]),
    ok = file:write_file(Sentinel, <<"external bytes">>),
    ok = file:make_symlink(External, Container),
    ?assertMatch({error, _}, command(Rebar, ["ldoc"], OtherRoot)),
    ?assertEqual({ok, <<"external bytes">>}, file:read_file(Sentinel)).

symlink_build_ancestor_is_refused(Rebar, Root, Workspace) ->
    Build = filename:join(Root, "_build"),
    External = filename:join(Workspace, "external-build"),
    ok = file:rename(Build, External),
    Sentinel = filename:join([External, "default", "keep"]),
    ok = file:write_file(Sentinel, <<"build sibling">>),
    ok = file:make_symlink(External, Build),
    Result = command(Rebar, ["ldoc"], Root),
    case Result of
        {error, {Status, Output}} when Status =/= 0 ->
            ?assertNotEqual(nomatch, binary:match(Output, <<"unsafe_ancestor">>));
        Other ->
            ?assertEqual(expected_nonzero_unsafe_ancestor, Other)
    end,
    ?assertEqual({ok, <<"build sibling">>}, file:read_file(Sentinel)).

make_plugin_source(Git, SourceRoot, PluginSource) ->
    ok = file:make_dir(PluginSource),
    lists:foreach(fun(Name) ->
        Source = filename:join(SourceRoot, Name),
        Target = filename:join(PluginSource, Name),
        case file:read_link_info(Source) of
            {ok, #file_info{type = directory}} -> copy_dir(Source, Target);
            {ok, #file_info{type = regular}} -> {ok, _} = file:copy(Source, Target)
        end
    end, ["src", "rebar.config", "rebar.lock"]),
    {ok, _} = command(Git, ["init", "-b", "main"], PluginSource),
    {ok, _} = command(Git, ["config", "user.name", "ldoc plugin test"], PluginSource),
    {ok, _} = command(Git, ["config", "user.email", "test@example.invalid"], PluginSource),
    {ok, _} = command(Git, ["add", "src", "rebar.config", "rebar.lock"], PluginSource),
    {ok, _} = command(Git, ["commit", "-m", "Create source-only plugin fixture"], PluginSource),
    ok.

copy_dir(Source, Target) ->
    ok = file:make_dir(Target),
    {ok, Names} = file:list_dir(Source),
    lists:foreach(fun(Name) ->
        From = filename:join(Source, Name),
        To = filename:join(Target, Name),
        case file:read_link_info(From) of
            {ok, #file_info{type = directory}} -> copy_dir(From, To);
            {ok, #file_info{type = regular}} -> {ok, _} = file:copy(From, To)
        end
    end, Names),
    ok.

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
    after 15000 ->
        _ = catch port_close(Port),
        {error, timeout}
    end.

tree(Root) ->
    tree_dir(Root, "").

site_contains(Root, Bytes) ->
    lists:any(fun({Name, Value}) ->
        lists:member("site", filename:split(Name)) andalso is_binary(Value) andalso
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
        {ok, _} -> file:delete(Path);
        {error, enoent} -> ok
    end.
