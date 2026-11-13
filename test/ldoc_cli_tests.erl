-module(ldoc_cli_tests).

-include_lib("eunit/include/eunit.hrl").

ldoc_cli_test_() ->
    {timeout, 240, fun() ->
        with_workspace(fun(Workspace, SiblingSentinel) ->
            help_and_usage(Workspace),
            prebuild_rejections(Workspace),
            guide_example_round_trip(Workspace),
            two_carrier_cli_build(Workspace),
            package_label_containment(Workspace),
            ordered_header_choices(Workspace),
            compiled_inventory_rejections(Workspace),
            malformed_edoc_retains_partial_root(Workspace),
            ?assertEqual({ok, <<"unrelated">>}, file:read_file(SiblingSentinel))
        end)
    end}.

help_and_usage(Workspace) ->
    ?assertEqual({ok, help}, ldoc_cli:run(["--help"])),
    ?assertMatch({error, {usage, missing_output}},
                 ldoc_cli:run(["build", "."])),
    ?assertMatch({error, {usage, missing_project}},
                 ldoc_cli:run(["build", "--not-an-option", "--output",
                               filename:join(Workspace, "unknown-option-output")])),
    ?assertMatch({error, {usage, {duplicate_option, "--output"}}},
                 ldoc_cli:run(["build", ".", "--output",
                               filename:join(Workspace, "first"), "--output",
                               filename:join(Workspace, "second")])),
    ?assertMatch({error, {usage, {unknown_or_missing_option, "--unknown"}}},
                 ldoc_cli:run(["build", ".", "--unknown", "x"])) .

prebuild_rejections(Workspace) ->
    Missing = filename:join(Workspace, "missing-project"),
    MissingOut = filename:join(Workspace, "missing-site"),
    ?assertMatch({error, {project, Missing, enoent}},
                 ldoc_cli:run(["build", Missing, "--output", MissingOut])),
    ?assertNot(filelib:is_file(MissingOut)),
    Umbrella = filename:join(Workspace, "umbrella"),
    UmbrellaOut = filename:join(Workspace, "umbrella-site"),
    ok = file:make_dir(Umbrella),
    ok = file:write_file(filename:join(Umbrella, "rebar.config"), <<"[].\n">>),
    ?assertMatch({error, {project, _, missing_source_directory}},
                 ldoc_cli:run(["build", Umbrella, "--output", UmbrellaOut])),
    ?assertNot(filelib:is_dir(UmbrellaOut)),
    Invalid = filename:join(Workspace, "invalid-base"),
    InvalidOut = filename:join(Workspace, "invalid-base-site"),
    create_project(Invalid),
    ?assertMatch({error, invalid_source_or_render_options},
                 ldoc_cli:run(["build", Invalid, "--output", InvalidOut,
                               "--source-base", "javascript:bad"])),
    ?assertNot(filelib:is_dir(InvalidOut)),
    Failing = filename:join(Workspace, "compile-failure"),
    FailingOut = filename:join(Workspace, "compile-failure-site"),
    create_project(Failing),
    ok = file:write_file(filename:join([Failing, "src", "cli_native.erl"]),
                         <<"-module(cli_native).\nbroken( ->.\n">>),
    PortsBefore = length(erlang:ports()),
    ?assertMatch({error, {compile, Failing, {exit_status, _}}},
                 ldoc_cli:run(["build", Failing, "--output", FailingOut])),
    ?assertNot(filelib:is_dir(FailingOut)),
    ?assertEqual(PortsBefore, length(erlang:ports())).

guide_example_round_trip(Workspace) ->
    Root = filename:join(Workspace, "guide-fixture"),
    ok = file:make_dir(Root),
    Fixture = filename:join([filename:dirname(filename:absname(?FILE)),
                              "fixtures", "ldoc-guide-example.lfe"]),
    {ok, [{ok, 'ldoc-guide-example', Beam, []}], []} =
        lfe_comp:file(Fixture, [binary, return]),
    BeamPath = filename:join(Root, "ldoc-guide-example.beam"),
    ok = file:write_file(BeamPath, Beam, [binary]),
    {ok, Module} = 'ldoc-beam':collect(BeamPath),
    ?assertEqual(<<"ldoc-guide-example">>, maps:get(name, Module)),
    ?assertEqual(#{<<"en">> => <<"Small arithmetic examples for documentation authors.">>},
                 maps:get(doc, Module)),
    Entries = maps:get(entries, Module),
    ?assert(lists:any(fun(E) -> maps:get(name, E) =:= <<"tagged">> andalso
                                maps:get(kind, E) =:= <<"macro">> andalso
                                maps:get(doc, E) =/= none end, Entries)),
    ?assert(lists:any(fun(E) -> maps:get(name, E) =:= <<"sign">> andalso
                                maps:get(doc, E) =/= none end, Entries)),
    Release = #{namespace => <<"test">>, package => <<"guide">>,
                version => <<"1">>},
    {ok, Docset} = 'ldoc-docset':assemble(Release, [BeamPath]),
    {ok, View} = 'ldoc-analysis':view(Docset),
    {ok, Files} = 'ldoc-html':render(View),
    HTML = iolist_to_binary([B || {_, B} <- Files]),
    ?assertNotEqual(nomatch, binary:match(HTML, <<"Small arithmetic examples">>)),
    ?assertNotEqual(nomatch, binary:match(HTML, <<"Classify an integer">>)),
    ?assertNotEqual(nomatch, binary:match(HTML, <<"Expand to a tuple">>)).

two_carrier_cli_build(Workspace) ->
    Root = filename:join(Workspace, "cli-project with spaces"),
    Output1 = filename:join(Workspace, "cli-output-one"),
    Output2 = filename:join(Workspace, "cli-output-two"),
    Existing = filename:join(Workspace, "cli-existing-output"),
    BeforePath = code:get_path(),
    Leader = group_leader(),
    create_project(Root),
    ok = file:make_dir(Existing),
    ExistingSentinel = filename:join(Existing, "keep.txt"),
    ok = file:write_file(ExistingSentinel, <<"keep">>),
    Sentinel = filename:join([Root, "doc", "chunks", "author.keep"]),
    ok = filelib:ensure_dir(Sentinel),
    ok = file:write_file(Sentinel, <<"author-owned">>),
    Args = ["build", Root, "--output", Output1,
            "--source-root", Root,
            "--source-base", "https://example.test/source/"],
    PortsBefore = length(erlang:ports()),
    {ok, Index1} = ldoc_cli:run(Args),
    ?assertEqual(PortsBefore, length(erlang:ports())),
    ?assert(is_binary(Index1)),
    ?assertEqual(filename:join([Output1, "site", "index.html"]),
                 binary_to_list(Index1)),
    ?assertEqual({ok, <<"author-owned">>}, file:read_file(Sentinel)),
    ?assertEqual(BeforePath, code:get_path()),
    ?assertEqual(Leader, group_leader()),
    ?assertEqual(false, code:is_loaded(cli_native)),
    ?assertEqual(false, code:is_loaded(cli_edoc)),
    {ok, Native} = find_module(Output1, <<"cli-package">>, <<"cli_native">>),
    ?assertEqual(embedded_beam, maps:get(carrier, maps:get(source, Native))),
    {ok, Edoc} = find_module(Output1, <<"cli-package">>, <<"cli_edoc">>),
    EdocSource = maps:get(source, Edoc),
    EdocText = iolist_to_binary(io_lib:format("~tp", [maps:get(doc, Edoc)])),
    ?assertNotEqual(nomatch, binary:match(EdocText, <<"EDoc module prose">>)),
    EdocEntries = iolist_to_binary(io_lib:format("~tp", [maps:get(entries, Edoc)])),
    ?assertNotEqual(nomatch,
                    binary:match(EdocEntries,
                                 <<"EDoc function prose from the enabled branch">>)),
    ?assertEqual(eep48_sidecar, maps:get(carrier, EdocSource)),
    Conversion = maps:get(conversion, EdocSource),
    ?assertEqual(filename:join([Root, "src", "cli_edoc.erl"]),
                 maps:get(source_path, Conversion)),
    ?assert(lists:member(filename:join(Root, "include"),
                         maps:get(include_paths, Conversion))),
    Args2 = ["build", Root, "--output", Output2,
             "--source-root", Root, "--source-base", "https://example.test/source/"],
    {ok, Index2} = ldoc_cli:run(Args2),
    ?assert(is_binary(Index2)),
    ?assertEqual(read_tree(filename:join(Output1, "site")),
                 read_tree(filename:join(Output2, "site"))),
    Release = #{namespace => <<"local">>, package => <<"cli-package">>,
                version => <<"1.2.3">>},
    {ok, Snapshot1} = 'ldoc-store':get(filename:join(Output1, "snapshots"), Release),
    {ok, Snapshot2} = 'ldoc-store':get(filename:join(Output2, "snapshots"), Release),
    ?assertEqual(normalize_snapshot(Snapshot1, Output1),
                 normalize_snapshot(Snapshot2, Output2)),
    ?assertMatch({error, {output, _, output_exists}}, ldoc_cli:run(Args)),
    ?assertEqual({ok, <<"author-owned">>}, file:read_file(Sentinel)),
    ExistingArgs = ["build", Root, "--output", Existing],
    ?assertMatch({error, {output, _, output_exists}}, ldoc_cli:run(ExistingArgs)),
    ?assertEqual({ok, <<"keep">>}, file:read_file(ExistingSentinel)),
    assert_cli_public_docs().

package_label_containment(Workspace) ->
    RelativeRoot = filename:join(Workspace, "relative-package-project"),
    RelativeOutput = filename:join(Workspace, "relative-package-output"),
    create_project(RelativeRoot),
    {ok, _} = ldoc_cli:run(["build", RelativeRoot, "--output", RelativeOutput,
                            "--package", "../escaped"]),
    {ok, RelativePackageModule} = find_module(RelativeOutput, <<"../escaped">>,
                                              <<"cli_native">>),
    ?assertEqual(<<"cli_native">>, maps:get(name, RelativePackageModule)),
    ?assertNot(filelib:is_dir(filename:join(Workspace, "escaped"))),
    ?assert(filelib:is_regular(filename:join([RelativeOutput, "package", "ebin",
                                              "cli_native.beam"]))),
    AbsoluteLabel = filename:join(Workspace, "absolute-label"),
    AbsoluteRoot = filename:join(Workspace, "absolute-package-project"),
    AbsoluteOutput = filename:join(Workspace, "absolute-package-output"),
    create_project(AbsoluteRoot),
    {ok, _} = ldoc_cli:run(["build", AbsoluteRoot, "--output", AbsoluteOutput,
                            "--package", AbsoluteLabel]),
    {ok, AbsolutePackageModule} = find_module(AbsoluteOutput,
                                              unicode:characters_to_binary(AbsoluteLabel),
                                              <<"cli_native">>),
    ?assertEqual(<<"cli_native">>, maps:get(name, AbsolutePackageModule)),
    ?assertNot(filelib:is_dir(AbsoluteLabel)),
    ?assert(filelib:is_regular(filename:join([AbsoluteOutput, "package", "ebin",
                                              "cli_native.beam"]))).

ordered_header_choices(Workspace) ->
    ordered_header_case(Workspace, "z_first", "a_second", "chosen_z"),
    ordered_header_case(Workspace, "a_second", "z_first", "chosen_a").

ordered_header_case(Workspace, FirstName, SecondName, ExpectedFunction) ->
    Label = lists:flatten(io_lib:format("headers-~s", [FirstName])),
    Root = filename:join(Workspace, Label),
    Output = filename:join(Workspace, Label ++ "-output"),
    create_ordered_header_project(Root, FirstName, SecondName),
    {ok, Index} = ldoc_cli:run(["build", Root, "--output", Output]),
    ?assert(is_binary(Index)),
    AppDir = filename:join([Root, "_build", "default", "lib", "header_fixture", "ebin"]),
    BeamPath = filename:join(AppDir, "header_edoc.beam"),
    {ok, {header_edoc, Chunks}} = beam_lib:chunks(BeamPath, [exports]),
    {exports, Exports} = lists:keyfind(exports, 1, Chunks),
    ?assert(lists:member({list_to_atom(ExpectedFunction), 0}, Exports)),
    OtherFunction = case ExpectedFunction of
        "chosen_z" -> "chosen_a";
        "chosen_a" -> "chosen_z"
    end,
    ?assertNot(lists:member({list_to_atom(OtherFunction), 0}, Exports)),
    {ok, Module} = find_module(Output, <<"header-package">>, <<"header_edoc">>),
    Entries = maps:get(entries, Module),
    ?assert(lists:any(fun(Entry) -> maps:get(name, Entry) =:=
                                      unicode:characters_to_binary(ExpectedFunction) end, Entries)),
    ?assertNot(lists:any(fun(Entry) -> maps:get(name, Entry) =:=
                                          unicode:characters_to_binary(OtherFunction) end, Entries)).

compiled_inventory_rejections(Workspace) ->
    inventory_rejection(Workspace, "missing",
      "rm _build/default/lib/cli_fixture/ebin/cli_edoc.beam", inventory),
    inventory_rejection(Workspace, "stale",
      "cp _build/default/lib/cli_fixture/ebin/cli_native.beam _build/default/lib/cli_fixture/ebin/stale.beam",
      inventory),
    inventory_rejection(Workspace, "wrong",
      "cp -f _build/default/lib/cli_fixture/ebin/cli_native.beam _build/default/lib/cli_fixture/ebin/cli_edoc.beam",
      identity).

inventory_rejection(Workspace, Label, Hook, ErrorTag) ->
    Root = filename:join(Workspace, "inventory-" ++ Label),
    Output = filename:join(Workspace, "inventory-output-" ++ Label),
    create_project(Root),
    Config = filename:join(Root, "rebar.config"),
    ok = file:write_file(Config,
        io_lib:format("{erl_opts, [debug_info, {i, \"include\"}, {d, edoc_enabled, true}]}.~n"
                      "{post_hooks, [{compile, \"~s\"}]}.~n", [Hook])),
    Result = ldoc_cli:run(["build", Root, "--output", Output]),
    ?assertMatch({error, {ErrorTag, _, _}}, Result),
    ?assertNot(filelib:is_dir(Output)).

malformed_edoc_retains_partial_root(Workspace) ->
    Root = filename:join(Workspace, "malformed-edoc-project"),
    Output = filename:join(Workspace, "malformed-edoc-output"),
    Leader = group_leader(),
    create_malformed_project(Root),
    Result = ldoc_cli:run(["build", Root, "--output", Output]),
    ?assertMatch({error, {stage, edoc, Output, _}}, Result),
    ?assert(filelib:is_dir(Output)),
    ?assert(filelib:is_regular(filename:join([Output, "package", "ebin",
                                              "bad_edoc.beam"]))),
    ?assertNot(filelib:is_regular(filename:join([Output, "site", "index.html"]))),
    ?assertEqual(Leader, group_leader()).

assert_cli_public_docs() ->
    BeamPath = code:which(ldoc_cli),
    {ok, Module} = 'ldoc-beam':collect(BeamPath),
    ?assertNotEqual(none, maps:get(doc, Module)),
    Entries = maps:get(entries, Module),
    lists:foreach(fun(Name) ->
        ?assert(lists:any(fun(Entry) -> maps:get(name, Entry) =:= Name andalso
                                        maps:get(doc, Entry) =/= none end, Entries))
    end, [<<"main">>, <<"run">>]).

create_malformed_project(Root) ->
    Src = filename:join(Root, "src"),
    ok = filelib:ensure_dir(filename:join(Src, "placeholder")),
    ok = file:write_file(filename:join(Root, "rebar.config"),
                         <<"{erl_opts, [debug_info]}.\n">>),
    ok = file:write_file(filename:join(Src, "bad_fixture.app.src"),
                         <<"{application, bad_fixture, [{description, \"Bad EDoc fixture\"}, {vsn, \"1\"}, {pkg_name, \"bad-package\"}, {applications, [kernel, stdlib]}, {modules, [bad_edoc]}]}.\n">>),
    ok = file:write_file(filename:join(Src, "bad_edoc.erl"),
                         <<"%% @doc <broken\n"
                           "-module(bad_edoc).\n"
                           "-export([run/0]).\n"
                           "%% @doc <broken\n"
                           "run() -> ok.\n">>),
    ok.

create_project(Root) ->
    Src = filename:join(Root, "src"),
    Include = filename:join(Root, "include"),
    ok = filelib:ensure_dir(filename:join(Src, "placeholder")),
    ok = filelib:ensure_dir(filename:join(Include, "placeholder")),
    ok = file:write_file(filename:join(Root, "rebar.config"),
                         <<"{erl_opts, [debug_info, {i, \"include\"}, {d, edoc_enabled, true}]} .\n">>),
    ok = file:write_file(filename:join(Src, "cli_fixture.app.src"),
                         <<"{application, cli_fixture, [{description, \"CLI fixture\"}, {vsn, \"1.2.3\"}, {pkg_name, \"cli-package\"}, {applications, [kernel, stdlib]}, {modules, [cli_edoc, cli_native]}]}.\n">>),
    ok = file:write_file(filename:join(Include, "cli_flags.hrl"),
                         <<"-define(CLI_VALUE, enabled_from_header).\n">>),
    ok = file:write_file(filename:join(Src, "cli_native.erl"),
                         <<"-module(cli_native).\n"
                           "-moduledoc(\"Native module prose.\").\n"
                           "-doc(\"Native function prose.\").\n"
                           "-export([native/0]).\n"
                           "native() -> native_value.\n">>),
    ok = file:write_file(filename:join(Src, "cli_edoc.erl"),
                         <<"%% @doc EDoc module prose.\n"
                           "-module(cli_edoc).\n"
                           "-export([edoc/0]).\n"
                           "-ifdef(edoc_enabled).\n"
                           "-include(\"cli_flags.hrl\").\n"
                           "%% @doc EDoc function prose from the enabled branch.\n"
                           "edoc() -> ?CLI_VALUE.\n"
                           "-else.\n"
                           "edoc() -> disabled.\n"
                           "-endif.\n">>),
    ok.

create_ordered_header_project(Root, FirstName, SecondName) ->
    Src = filename:join(Root, "src"),
    First = filename:join(Root, FirstName),
    Second = filename:join(Root, SecondName),
    ok = filelib:ensure_dir(filename:join(Src, "placeholder")),
    ok = filelib:ensure_dir(filename:join(First, "placeholder")),
    ok = filelib:ensure_dir(filename:join(Second, "placeholder")),
    Config = io_lib:format("{erl_opts, [debug_info, {i, \"~s\"}, {i, \"~s\"}, {d, edoc_enabled, true}]}.~n",
                           [FirstName, SecondName]),
    ok = file:write_file(filename:join(Root, "rebar.config"), Config),
    ok = file:write_file(filename:join(Src, "header_fixture.app.src"),
        <<"{application, header_fixture, [{description, \"Header order fixture\"}, {vsn, \"1\"}, {pkg_name, \"header-package\"}, {applications, [kernel, stdlib]}, {modules, [header_edoc]}]}.\n">>),
    ok = file:write_file(filename:join(First, "choice.hrl"),
                         io_lib:format("-define(SELECTED, ~s).~n",
                                       [header_choice(FirstName)])),
    ok = file:write_file(filename:join(Second, "choice.hrl"),
                         io_lib:format("-define(SELECTED, ~s).~n",
                                       [header_choice(SecondName)])),
    ok = file:write_file(filename:join(Src, "header_edoc.erl"),
                         <<"%% @doc Header choice module prose.\n"
                           "-module(header_edoc).\n"
                           "-ifdef(edoc_enabled).\n"
                           "-include(\"choice.hrl\").\n"
                           "-export([?SELECTED/0]).\n"
                           "%% @doc The selected include supplies this function.\n"
                           "?SELECTED() -> ok.\n"
                           "-endif.\n">>),
    ok.

header_choice("z_first") -> "chosen_z";
header_choice("a_second") -> "chosen_a".

find_module(Output, Package, Name) ->
    Store = filename:join(Output, "snapshots"),
    Release = #{namespace => <<"local">>, package => Package,
                version => case Package of
                    <<"header-package">> -> <<"1">>;
                    _ -> <<"1.2.3">>
                end},
    {ok, Docset} = 'ldoc-store':get(Store, Release),
    case [M || M <- maps:get(modules, Docset), maps:get(name, M) =:= Name] of
        [Module] -> {ok, Module};
        _ -> error
    end.

read_tree(Root) -> lists:sort(tree_entries(Root, "" )).
tree_entries(Root, Relative) ->
    Directory = filename:join(Root, Relative),
    {ok, Names} = file:list_dir(Directory),
    lists:append([tree_entry(Root, Relative, Name) || Name <- Names]).
tree_entry(Root, Relative, Name) ->
    Child = case Relative of
        "" -> Name;
        _ -> filename:join(Relative, Name)
    end,
    Path = filename:join(Root, Child),
    case filelib:is_dir(Path) of
        true -> tree_entries(Root, Child);
        false -> [{Child, read_file(Path)}]
    end.
read_file(Path) -> {ok, Bytes} = file:read_file(Path), Bytes.

normalize_snapshot(Docset, Output) ->
    Modules = [Module#{source := normalize_source(maps:get(source, Module), Output)}
               || Module <- maps:get(modules, Docset)],
    Docset#{modules := Modules}.

normalize_source(Source, Output) ->
    lists:foldl(fun(Key, Acc) ->
        case maps:find(Key, Acc) of
            {ok, Value} when is_list(Value) ->
                Prefix = Output ++ "/",
                case lists:prefix(Prefix, Value) of
                    true -> maps:put(Key, "<fresh-root>/" ++
                                        lists:nthtail(length(Prefix), Value), Acc);
                    false -> Acc
                end;
            _ -> Acc
        end
    end, Source, [path, beam_path]).

with_workspace(Fun) ->
    OwnedRoot = claim_workspace(32),
    Workspace = filename:join(OwnedRoot, "working"),
    Sentinel = filename:join(OwnedRoot, "sibling-sentinel"),
    ok = file:make_dir(Workspace),
    ok = file:write_file(Sentinel, <<"unrelated">>, [binary, exclusive]),
    try Fun(Workspace, Sentinel)
    after
        ok = file:del_dir_r(Workspace),
        {ok, <<"unrelated">>} = file:read_file(Sentinel),
        ok = file:del_dir_r(OwnedRoot)
    end.

claim_workspace(Attempts) when Attempts > 0 ->
    Name = "ldoc-cli-tests-" ++ os:getpid() ++ "-" ++
           integer_to_list(erlang:unique_integer([positive, monotonic])),
    Path = filename:join("/tmp", Name),
    case file:make_dir(Path) of
        ok -> Path;
        {error, eexist} -> claim_workspace(Attempts - 1);
        {error, Reason} -> erlang:error({workspace_claim, Path, Reason})
    end;
claim_workspace(0) -> erlang:error(workspace_claim_exhausted).
