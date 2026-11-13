-module(ldoc_cli_tests).

-include_lib("eunit/include/eunit.hrl").

ldoc_cli_test_() ->
    {timeout, 240, fun() ->
        help_and_usage(),
        prebuild_rejections(),
        guide_example_round_trip(),
        two_carrier_cli_build(),
        compiled_inventory_rejections(),
        malformed_edoc_retains_partial_root()
    end}.

help_and_usage() ->
    ?assertEqual({ok, help}, ldoc_cli:run(["--help"])),
    ?assertMatch({error, {usage, missing_output}},
                 ldoc_cli:run(["build", "."])),
    ?assertMatch({error, {usage, {duplicate_option, "--output"}}},
                 ldoc_cli:run(["build", ".", "--output", "/tmp/a",
                               "--output", "/tmp/b"])),
    ?assertMatch({error, {usage, {unknown_or_missing_option, "--unknown"}}},
                 ldoc_cli:run(["build", ".", "--unknown", "x"])) .

prebuild_rejections() ->
    Missing = filename:join("/tmp", "ldoc-missing-project-" ++
                            integer_to_list(erlang:unique_integer([positive]))),
    MissingOut = Missing ++ "-site",
    ?assertMatch({error, {project, Missing, enoent}},
                 ldoc_cli:run(["build", Missing, "--output", MissingOut])),
    ?assertNot(filelib:is_file(MissingOut)),
    Umbrella = temp_root("ldoc umbrella "),
    UmbrellaOut = filename:join(filename:dirname(Umbrella), "ldoc umbrella site"),
    try
        ok = file:write_file(filename:join(Umbrella, "rebar.config"), <<"[].\n">>),
        ?assertMatch({error, {project, _, missing_source_directory}},
                     ldoc_cli:run(["build", Umbrella, "--output", UmbrellaOut])),
        ?assertNot(filelib:is_dir(UmbrellaOut))
    after
        _ = file:del_dir_r(Umbrella),
        _ = file:del_dir_r(UmbrellaOut)
    end,
    Invalid = temp_root("ldoc invalid base "),
    InvalidOut = filename:join(filename:dirname(Invalid), "ldoc invalid base site"),
    try
        create_project(Invalid),
        ?assertMatch({error, invalid_source_or_render_options},
                     ldoc_cli:run(["build", Invalid, "--output", InvalidOut,
                                   "--source-base", "javascript:bad"])),
        ?assertNot(filelib:is_dir(InvalidOut))
    after
        _ = file:del_dir_r(Invalid),
        _ = file:del_dir_r(InvalidOut)
    end,
    Failing = temp_root("ldoc compile failure "),
    FailingOut = filename:join(filename:dirname(Failing), "ldoc compile failure site"),
    try
        create_project(Failing),
        ok = file:write_file(filename:join([Failing, "src", "cli_native.erl"]),
                             <<"-module(cli_native).\nbroken( ->.\n">>),
        ?assertMatch({error, {compile, Failing, {exit_status, _}}},
                     ldoc_cli:run(["build", Failing, "--output", FailingOut])),
        ?assertNot(filelib:is_dir(FailingOut))
    after
        _ = file:del_dir_r(Failing),
        _ = file:del_dir_r(FailingOut)
    end.

guide_example_round_trip() ->
    Root = temp_root("ldoc-cli-guide"),
    try
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
        ?assertNotEqual(nomatch, binary:match(HTML, <<"Expand to a tuple">>))
    after
        _ = file:del_dir_r(Root)
    end.

two_carrier_cli_build() ->
    Root = temp_root("ldoc cli project "),
    Output1 = filename:join(filename:dirname(Root), "ldoc cli output one"),
    Output2 = filename:join(filename:dirname(Root), "ldoc cli output two"),
    Existing = filename:join(filename:dirname(Root), "ldoc cli existing output"),
    BeforePath = code:get_path(),
    try
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
        ?assertMatch({ok, _}, ldoc_cli:run(Args)),
        ?assertEqual({ok, <<"author-owned">>}, file:read_file(Sentinel)),
        ?assertEqual(BeforePath, code:get_path()),
        ?assertEqual(false, code:is_loaded(cli_native)),
        ?assertEqual(false, code:is_loaded(cli_edoc)),
        {ok, Native} = find_module(Output1, <<"cli_native">>),
        ?assertEqual(embedded_beam, maps:get(carrier, maps:get(source, Native))),
        {ok, Edoc} = find_module(Output1, <<"cli_edoc">>),
        EdocSource = maps:get(source, Edoc),
        EdocText = iolist_to_binary(io_lib:format("~tp", [maps:get(doc, Edoc)])),
        ?assertNotEqual(nomatch,
                        binary:match(EdocText, <<"EDoc module prose">>)),
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
        ?assertMatch({ok, _}, ldoc_cli:run(Args2)),
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
        ?assertEqual({ok, <<"keep">>}, file:read_file(ExistingSentinel))
    after
        _ = file:del_dir_r(Output1),
        _ = file:del_dir_r(Output2),
        _ = file:del_dir_r(Existing),
        _ = file:del_dir_r(Root)
    end.

malformed_edoc_retains_partial_root() ->
    Root = temp_root("ldoc malformed edoc "),
    Output = filename:join(filename:dirname(Root), "ldoc malformed output " ++
                           integer_to_list(erlang:unique_integer([positive]))),
    Leader = group_leader(),
    try
        create_malformed_project(Root),
        Result = ldoc_cli:run(["build", Root, "--output", Output]),
        ?assertMatch({error, {stage, edoc, Output, _}}, Result),
        ?assert(filelib:is_dir(Output)),
        ?assert(filelib:is_regular(filename:join([Output, "bad-package", "ebin",
                                                  "bad_edoc.beam"]))),
        ?assertNot(filelib:is_regular(filename:join([Output, "site", "index.html"]))),
        ?assertEqual(Leader, group_leader())
    after
        _ = file:del_dir_r(Output),
        _ = file:del_dir_r(Root)
    end.

compiled_inventory_rejections() ->
    inventory_rejection("missing",
      "rm _build/default/lib/cli_fixture/ebin/cli_edoc.beam", inventory),
    inventory_rejection("stale",
      "cp _build/default/lib/cli_fixture/ebin/cli_native.beam _build/default/lib/cli_fixture/ebin/stale.beam",
      inventory),
    inventory_rejection("wrong",
      "cp -f _build/default/lib/cli_fixture/ebin/cli_native.beam _build/default/lib/cli_fixture/ebin/cli_edoc.beam",
      identity).

inventory_rejection(Label, Hook, ErrorTag) ->
    Root = temp_root("ldoc inventory " ++ Label ++ " "),
    Output = filename:join(filename:dirname(Root), "ldoc inventory output " ++ Label ++ " " ++
                           integer_to_list(erlang:unique_integer([positive]))),
    try
        create_project(Root),
        Config = filename:join(Root, "rebar.config"),
        ok = file:write_file(Config,
            io_lib:format("{erl_opts, [debug_info, {i, \"include\"}, {d, edoc_enabled, true}]}.~n"
                          "{post_hooks, [{compile, \"~s\"}]}.~n", [Hook])),
        Result = ldoc_cli:run(["build", Root, "--output", Output]),
        ?assertMatch({error, {ErrorTag, _, _}}, Result),
        ?assertNot(filelib:is_dir(Output))
    after
        _ = file:del_dir_r(Output),
        _ = file:del_dir_r(Root)
    end.

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

find_module(Output, Name) ->
    Store = filename:join(Output, "snapshots"),
    Release = #{namespace => <<"local">>, package => <<"cli-package">>,
                version => <<"1.2.3">>},
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
                case lists:prefix(Output, Value) of
                    true -> maps:put(Key, "<fresh-root>" ++ lists:nthtail(length(Output), Value), Acc);
                    false -> Acc
                end;
            _ -> Acc
        end
    end, Source, [path, beam_path]).

temp_root(Prefix) ->
    Root = filename:join("/tmp", Prefix ++ "-" ++
                         integer_to_list(erlang:unique_integer([positive, monotonic]))),
    ok = file:make_dir(Root),
    Root.
