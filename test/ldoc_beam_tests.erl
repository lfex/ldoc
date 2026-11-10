-module(ldoc_beam_tests).

-include_lib("eunit/include/eunit.hrl").

ldoc_beam_test_() ->
    {setup, fun setup/0, fun cleanup/1,
     fun(Temp) -> ?_test(run(Temp)) end}.

setup() ->
    make_temp_dir(os:getenv("TMPDIR", "/tmp"), 0).

make_temp_dir(_Base, Attempts) when Attempts >= 20 ->
    erlang:error(temporary_directory_exhausted);
make_temp_dir(Base, Attempts) ->
    Name = "ldoc-eep48-" ++ os:getpid() ++ "-" ++
           integer_to_list(erlang:unique_integer([positive, monotonic])),
    Temp = filename:join(Base, Name),
    case file:make_dir(Temp) of
        ok -> Temp;
        {error, eexist} -> make_temp_dir(Base, Attempts + 1);
        {error, Reason} -> erlang:error({temporary_directory, Reason})
    end.

cleanup(Temp) ->
    _ = file:del_dir_r(Temp),
    ok.

run(Temp) ->
    SourceDir = filename:dirname(filename:absname(?FILE)),
    LfeSource = filename:join([SourceDir, "fixtures", "ldoc-fixture.lfe"]),
    ErlFixture = filename:join([SourceDir, "fixtures", "ldoc_modern.erl.src"]),
    ErlSource = filename:join(Temp, "ldoc_modern.erl"),
    {ok, _} = file:copy(ErlFixture, ErlSource),
    {ok, [{ok, 'ldoc-fixture', LfeBeam, _FixtureWarnings}], _Warnings} =
        lfe_comp:file(LfeSource, [binary, return]),
    {ok, ldoc_modern, ErlBeam, _Warnings2} =
        compile:file(ErlSource, [binary, return_errors, return_warnings]),
    LfePath = write_beam(Temp, "ldoc-fixture.beam", LfeBeam),
    ErlPath = write_beam(Temp, "ldoc-modern.beam", ErlBeam),
    eep_s01(LfePath),
    eep_s02(LfePath),
    eep_s03(Temp, ErlPath, ErlBeam),
    eep_s04(Temp, LfeBeam),
    eep_s05(Temp, LfeSource, LfeBeam),
    erl_s01_collect(LfePath, ErlPath),
    Classic = erl_s02(Temp),
    erl_s03_collect(Temp, Classic),
    erl_s04_collect(Temp, LfeBeam),
    LegacyFixture = filename:join([SourceDir, "fixtures",
                                  "ldoc-legacy.beam.fixture"]),
    LegacyBeamPath = filename:join(Temp, "ldoc-legacy.beam"),
    {ok, _} = file:copy(LegacyFixture, LegacyBeamPath),
    {ok, LegacyBeam} = file:read_file(LegacyBeamPath),
    ldo_s01(LegacyBeamPath),
    ldo_s02(Temp, LegacyBeam),
    ldo_s03_collect(Temp, LfePath, ErlPath, Classic, LegacyBeam).

eep_s01(LfePath) ->
    ?assert(filelib:is_regular(code:which('ldoc-beam'))),
    ?assertMatch({ok, _}, 'ldoc-beam':'read-docs'(LfePath)).

eep_s02(LfePath) ->
    {ok, Module} = 'ldoc-beam':'read-docs'(LfePath),
    ?assertEqual(<<"ldoc-fixture">>, maps:get(name, Module)),
    ?assertEqual(<<"lfe">>, maps:get(language, Module)),
    ?assertEqual(<<"text/markdown">>, maps:get(format, Module)),
    ?assertEqual(#{<<"en">> => <<"Fixture module.">>},
                 maps:get(doc, Module)),
    ?assertEqual(1, erl_anno:line(maps:get(annotation, Module))),
    ?assertEqual(#{carrier => embedded_beam, path => LfePath,
                   chunk => <<"Docs">>}, maps:get(source, Module)),
    Metadata = maps:get(metadata, Module),
    ?assertEqual({1, 0, 0}, maps:get(otp_doc_vsn, Metadata)),
    Entries = maps:get(entries, Module),
    ?assertEqual(
       [{<<"function">>, <<"LFE-EXPAND-EXPORTED-MACRO">>, 3},
        {<<"function">>, <<"bare">>, 0},
        {<<"function">>, <<"sample">>, 1},
        {<<"function">>, <<"sample">>, 2},
        {<<"macro">>, <<"show">>, 1}],
       entry_keys(Entries)),
    ?assertEqual(false,
                 lists:any(fun(E) -> maps:get(name, E) =:= <<"private-fun">> end,
                           Entries)),
    assert_entry(Entries, <<"function">>,
                 <<"LFE-EXPAND-EXPORTED-MACRO">>, 3, 1,
                 [<<"LFE-EXPAND-EXPORTED-MACRO/3">>], none, internal),
    assert_entry(Entries, <<"function">>, <<"bare">>, 0, 14,
                 [<<"bare/0">>], none, candidate),
    assert_entry(Entries, <<"function">>, <<"sample">>, 1, 6,
                 [<<"sample/1">>],
                 #{<<"en">> => <<"One argument.">>}, candidate),
    assert_entry(Entries, <<"function">>, <<"sample">>, 2, 10,
                 [<<"sample/2">>],
                 #{<<"en">> => <<"Two arguments.">>}, candidate),
    assert_entry(Entries, <<"macro">>, <<"show">>, 1, 21,
                 [<<"show/1">>],
                 #{<<"en">> => <<"Display one argument.">>}, candidate).

eep_s03(Temp, ErlPath, ErlBeam) ->
    {ok, Module} = 'ldoc-beam':'read-docs'(ErlPath),
    Entries = maps:get(entries, Module),
    ?assertEqual(
       [{<<"callback">>, <<"get">>, 0},
        {<<"function">>, <<"hidden">>, 0},
        {<<"function">>, <<"show">>, 1},
        {<<"type">>, <<"value">>, 0}],
       entry_keys(Entries)),
    ?assertEqual(<<"erlang">>, maps:get(language, Module)),
    ?assertEqual(hidden,
                 entry_doc(Entries, <<"function">>, <<"hidden">>, 0)),
    DocMap = #{<<"en">> => <<"One">>, <<"fr">> => <<"Un">>},
    MultiPath = write_beam(Temp, "multi-locale.beam",
                           replace_doc(ErlBeam, {function, show, 1}, DocMap)),
    {ok, MultiModule} = 'ldoc-beam':'read-docs'(MultiPath),
    ?assertEqual(DocMap, entry_doc(maps:get(entries, MultiModule),
                                  <<"function">>, <<"show">>, 1)),
    EmptyPath = write_beam(Temp, "empty-locale.beam",
                           replace_doc(ErlBeam, {function, show, 1}, #{})),
    {ok, EmptyModule} = 'ldoc-beam':'read-docs'(EmptyPath),
    ?assertEqual(#{}, entry_doc(maps:get(entries, EmptyModule),
                               <<"function">>, <<"show">>, 1)),
    Structured = [{p, [], [<<"Example">>]}],
    StructuredBeam = replace_format_and_doc(
                       ErlBeam, <<"application/erlang+html">>,
                       {function, show, 1}, #{<<"en">> => Structured}),
    StructuredPath = write_beam(Temp, "structured-doc.beam", StructuredBeam),
    {ok, StructuredModule} = 'ldoc-beam':'read-docs'(StructuredPath),
    ?assertEqual(<<"application/erlang+html">>,
                 maps:get(format, StructuredModule)),
    ?assertEqual(#{<<"en">> => Structured},
                 entry_doc(maps:get(entries, StructuredModule),
                           <<"function">>, <<"show">>, 1)).

eep_s04(Temp, LfeBeam) ->
    Missing = filename:join(Temp, "missing.beam"),
    ?assertEqual({error, {read_beam, enoent}}, 'ldoc-beam':'read-docs'(Missing)),
    InvalidPath = write_beam(Temp, "invalid.beam", <<"not a BEAM">>),
    ?assertEqual({error, invalid_beam}, 'ldoc-beam':'read-docs'(InvalidPath)),
    MissingDocsBeam = remove_chunk(LfeBeam, "Docs"),
    MissingDocsPath = write_beam(Temp, "missing-docs.beam", MissingDocsBeam),
    ?assertEqual({error, missing_docs},
                 'ldoc-beam':'read-docs'(MissingDocsPath)),
    ValidTerm = docs_term(LfeBeam),
    CorruptPath = write_beam(Temp, "corrupt-etf.beam",
                             replace_docs(LfeBeam, <<1, 2, 3>>)),
    ?assertEqual({error, invalid_docs}, 'ldoc-beam':'read-docs'(CorruptPath)),
    Trailing = <<(term_to_binary(ValidTerm))/binary, 0>>,
    TrailingPath = write_beam(Temp, "trailing-etf.beam",
                              replace_docs(LfeBeam, Trailing)),
    ?assertEqual({error, invalid_docs}, 'ldoc-beam':'read-docs'(TrailingPath)),
    WrongPath = write_beam(Temp, "wrong-envelope.beam",
                           replace_docs(LfeBeam, term_to_binary(not_docs_v1))),
    ?assertEqual({error, invalid_docs}, 'ldoc-beam':'read-docs'(WrongPath)),
    Entries = element(7, ValidTerm),
    [First | Rest] = Entries,
    Identity = element(1, First),
    Negative = setelement(1, First, setelement(3, Identity, -1)),
    NegativePath = write_beam(
                     Temp, "negative-arity.beam",
                     replace_docs(LfeBeam,
                                  term_to_binary(setelement(7, ValidTerm,
                                                           [Negative | Rest])))),
    ?assertEqual({error, invalid_docs}, 'ldoc-beam':'read-docs'(NegativePath)),
    DuplicatePath = write_beam(
                      Temp, "duplicate-entry.beam",
                      replace_docs(LfeBeam,
                                   term_to_binary(setelement(7, ValidTerm,
                                                            [First, First])))),
    ?assertEqual({error, invalid_docs}, 'ldoc-beam':'read-docs'(DuplicatePath)),
    BadSignature = setelement(3, First, [<<"sample/1">> | malformed]),
    BadSignaturePath = write_beam(
                         Temp, "improper-signatures.beam",
                         replace_docs(LfeBeam,
                                      term_to_binary(setelement(7, ValidTerm,
                                                               [BadSignature | Rest])))),
    ?assertEqual({error, invalid_docs},
                 'ldoc-beam':'read-docs'(BadSignaturePath)),
    BadEntriesPath = write_beam(
                       Temp, "improper-entries.beam",
                       replace_docs(LfeBeam,
                                    term_to_binary(setelement(7, ValidTerm,
                                                             [First | malformed])))),
    ?assertEqual({error, invalid_docs},
                 'ldoc-beam':'read-docs'(BadEntriesPath)),
    BadMetadata = setelement(5, First, #{<<"invalid-key">> => true}),
    BadMetadataPath = write_beam(
                        Temp, "invalid-metadata-keys.beam",
                        replace_docs(LfeBeam,
                                     term_to_binary(setelement(7, ValidTerm,
                                                              [BadMetadata | Rest])))),
    ?assertEqual({error, invalid_docs},
                 'ldoc-beam':'read-docs'(BadMetadataPath)),
    BadFormatTerm = setelement(4, ValidTerm, not_binary),
    BadFormatPath = write_beam(
                      Temp, "invalid-format-type.beam",
                      replace_docs(LfeBeam, term_to_binary(BadFormatTerm))),
    ?assertEqual({error, invalid_docs},
                 'ldoc-beam':'read-docs'(BadFormatPath)),
    BadFormatStructuredTerm = setelement(
                                5,
                                setelement(4, ValidTerm, not_binary),
                                #{<<"en">> => [{p, [], [<<"Example">>]}]}),
    BadFormatStructuredPath = write_beam(
                                Temp, "invalid-format-structured-doc.beam",
                                replace_docs(LfeBeam,
                                             term_to_binary(BadFormatStructuredTerm))),
    ?assertEqual({error, invalid_docs},
                 'ldoc-beam':'read-docs'(BadFormatStructuredPath)),
    BadModuleMetadataTerm = setelement(6, ValidTerm, not_a_map),
    BadModuleMetadataPath = write_beam(
                              Temp, "invalid-module-metadata.beam",
                              replace_docs(LfeBeam,
                                           term_to_binary(BadModuleMetadataTerm))),
    ?assertEqual({error, invalid_docs},
                 'ldoc-beam':'read-docs'(BadModuleMetadataPath)),
    BadEntryMetadata = setelement(5, First, not_a_map),
    BadEntryMetadataPath = write_beam(
                             Temp, "invalid-entry-metadata.beam",
                             replace_docs(LfeBeam,
                                          term_to_binary(setelement(
                                                           7, ValidTerm,
                                                           [BadEntryMetadata | Rest])))),
    ?assertEqual({error, invalid_docs},
                 'ldoc-beam':'read-docs'(BadEntryMetadataPath)),
    {ok, BadAtomBeam} = beam_lib:build_module([{ "AtU8", <<>>}]),
    BadAtomPath = write_beam(Temp, "invalid-atoms.beam", BadAtomBeam),
    ?assertEqual({error, invalid_beam},
                 'ldoc-beam':'read-docs'(BadAtomPath)),
    {ok, BadUtf8Beam} = beam_lib:build_module(
                          [{"AtU8", <<1:32, 1, 255>>}]),
    BadUtf8Path = write_beam(Temp, "invalid-utf8-atoms.beam", BadUtf8Beam),
    ?assertEqual({error, invalid_beam},
                 'ldoc-beam':'read-docs'(BadUtf8Path)),
    {ok, BadLengthBeam} = beam_lib:build_module(
                            [{"AtU8", <<1:32, 2, $a>>}]),
    BadLengthPath = write_beam(Temp, "invalid-atom-length.beam", BadLengthBeam),
    ?assertEqual({error, invalid_beam},
                 'ldoc-beam':'read-docs'(BadLengthPath)).

eep_s05(Temp, LfeSource, LfeBeam) ->
    TargetDir = filename:join(Temp, "target"),
    DecoyDir = filename:join(Temp, "decoy"),
    ok = file:make_dir(TargetDir),
    ok = file:make_dir(DecoyDir),
    TargetPath = write_beam(TargetDir, "ldoc-fixture.beam", LfeBeam),
    {ok, SourceBytes} = file:read_file(LfeSource),
    DecoyBytes = binary:replace(SourceBytes, <<"Fixture module.">>,
                                <<"Decoy module.">>),
    DecoySource = filename:join(DecoyDir, "ldoc-fixture.lfe"),
    ok = file:write_file(DecoySource, DecoyBytes),
    {ok, [{ok, 'ldoc-fixture', DecoyBeam, _FixtureWarnings}], _Warnings} =
        lfe_comp:file(DecoySource, [binary, return]),
    _ = write_beam(DecoyDir, "ldoc-fixture.beam", DecoyBeam),
    ?assertEqual(false, code:is_loaded('ldoc-fixture')),
    true = code:add_patha(DecoyDir),
    try
        PathBefore = code:get_path(),
        {ok, Module} = 'ldoc-beam':'read-docs'(list_to_binary(TargetPath)),
        ?assertEqual(#{<<"en">> => <<"Fixture module.">>},
                     maps:get(doc, Module)),
        ?assertEqual(list_to_binary(TargetPath),
                     maps:get(path, maps:get(source, Module))),
        ?assertEqual(PathBefore, code:get_path()),
        ?assertEqual(false, code:is_loaded('ldoc-fixture'))
    after
        true = code:del_path(DecoyDir)
    end.

erl_s01_collect(LfePath, ErlPath) ->
    {ok, Lfe} = 'ldoc-beam':collect(LfePath),
    {ok, LfeRead} = 'ldoc-beam':'read-docs'(LfePath),
    ?assertEqual(LfeRead, Lfe),
    {ok, LfeDeclared} = 'ldoc-beam':collect(
                          LfePath, {edoc, LfePath, []}),
    ?assertEqual(Lfe, LfeDeclared),
    ?assertEqual(false, maps:is_key(conversion, maps:get(source, LfeDeclared))),
    ?assertEqual(
       #{carrier => embedded_beam,
         name => <<"ldoc-fixture">>, language => <<"lfe">>,
         entries => [
          {{<<"function">>, <<"LFE-EXPAND-EXPORTED-MACRO">>, 3}, none, internal},
          {{<<"function">>, <<"bare">>, 0}, none, candidate},
          {{<<"function">>, <<"sample">>, 1},
           #{<<"en">> => <<"One argument.">>}, candidate},
          {{<<"function">>, <<"sample">>, 2},
           #{<<"en">> => <<"Two arguments.">>}, candidate},
          {{<<"macro">>, <<"show">>, 1},
           #{<<"en">> => <<"Display one argument.">>}, candidate}]},
       consumer_projection(Lfe)),
    {ok, Erlang} = 'ldoc-beam':collect(ErlPath),
    {ok, ErlangRead} = 'ldoc-beam':'read-docs'(ErlPath),
    ?assertEqual(ErlangRead, Erlang),
    ?assertEqual(
       #{carrier => embedded_beam,
         name => <<"ldoc_modern">>, language => <<"erlang">>,
         entries => [
          {{<<"callback">>, <<"get">>, 0}, #{<<"en">> => <<"Get a value.">>}, candidate},
          {{<<"function">>, <<"hidden">>, 0}, hidden, candidate},
          {{<<"function">>, <<"show">>, 1},
           #{<<"en">> => <<"Show one value.">>}, candidate},
          {{<<"type">>, <<"value">>, 0},
           #{<<"en">> => <<"A fixture value type.">>}, candidate}]},
       consumer_projection(Erlang)).

consumer_projection(Module) ->
    #{carrier => maps:get(carrier, maps:get(source, Module)),
      name => maps:get(name, Module),
      language => maps:get(language, Module),
      entries => [{ {maps:get(kind, E), maps:get(name, E), maps:get(arity, E)},
                    maps:get(doc, E), maps:get(visibility, E)} ||
                    E <- maps:get(entries, Module)]}.

erl_s02(Temp) ->
    FixtureDir = filename:join([filename:dirname(filename:absname(?FILE)),
                                "fixtures"]),
    SourceFixture = filename:join(FixtureDir, "ldoc_classic.erl.src"),
    HeaderFixture = filename:join([FixtureDir, "edoc_include",
                                   "ldoc_classic.hrl"]),
    SourcePath = filename:join(Temp, "ldoc_classic.erl"),
    IncludeDir = filename:join(Temp, "include"),
    ok = file:make_dir(IncludeDir),
    HeaderPath = filename:join(IncludeDir, "ldoc_classic.hrl"),
    {ok, _} = file:copy(SourceFixture, SourcePath),
    {ok, _} = file:copy(HeaderFixture, HeaderPath),
    {ok, ldoc_classic, Beam} = compile:file(SourcePath, [binary, {i, IncludeDir}]),
    ?assertMatch({ok, {ldoc_classic, [{"Docs", missing_chunk}]}},
                 beam_lib:chunks(Beam, ["Docs"], [allow_missing_chunks])),
    Package = package_dirs(Temp, "edoc-package"),
    EbinDir = maps:get(ebin, Package),
    DocDir = maps:get(doc, Package),
    BeamPath = write_beam(EbinDir, "ldoc_classic.beam", Beam),
    ?assertEqual(ok,
                 edoc:files([SourcePath],
                            [{dir, DocDir},
                             {doclet, edoc_doclet_chunks},
                             {layout, edoc_layout_chunks},
                             {preprocess, true},
                             {includes, [IncludeDir]}])),
    ChunkPath = filename:join([DocDir, "chunks", "ldoc_classic.chunk"]),
    ?assert(filelib:is_regular(ChunkPath)),
    {ok, Plain} = 'ldoc-beam':collect(BeamPath),
    ?assertEqual(<<"ldoc_classic">>, maps:get(name, Plain)),
    ?assertEqual(<<"erlang">>, maps:get(language, Plain)),
    ?assertEqual(<<"application/erlang+html">>, maps:get(format, Plain)),
    ?assertEqual(2, erl_anno:line(maps:get(annotation, Plain))),
    ?assertEqual(#{<<"en">> => [{p, [], [<<"A module documented with EDoc.">>]}]},
                 maps:get(doc, Plain)),
    [PlainEntry] = maps:get(entries, Plain),
    ?assertEqual({<<"function">>, <<"show">>, 1},
                 {maps:get(kind, PlainEntry), maps:get(name, PlainEntry),
                  maps:get(arity, PlainEntry)}),
    ?assertEqual(7, erl_anno:line(maps:get(annotation, PlainEntry))),
    ?assertEqual([<<"show(X)">>], maps:get(signatures, PlainEntry)),
    ?assertEqual(#{<<"en">> => [{p, [], [<<"Show the input.">>]}]},
                 maps:get(doc, PlainEntry)),
    ?assertEqual(false, maps:is_key(conversion, maps:get(source, Plain))),
    ?assertEqual(#{carrier => eep48_sidecar,
                   path => filename:absname(ChunkPath),
                   beam_path => BeamPath}, maps:get(source, Plain)),
    {ok, Declared} = 'ldoc-beam':collect(
                       BeamPath, {edoc, SourcePath, [IncludeDir]}),
    ?assertEqual(#{tool => edoc, source_path => SourcePath,
                   include_paths => [IncludeDir], evidence => caller_declared},
                 maps:get(conversion, maps:get(source, Declared))),
    ?assertEqual(Plain#{source := (maps:get(source, Plain))#{conversion =>
                         maps:get(conversion, maps:get(source, Declared))}},
                 Declared),
    Spec = maps:get(signature, maps:get(metadata, PlainEntry)),
    ?assertMatch([{attribute, 6, spec,
                   {{show, 1},
                    [{type, 6, 'fun',
                      [{type, 6, product,
                        [{ann_type, 6,
                          [{var, 6, 'X'}, {type, 6, integer, []}]}]},
                       {type, 6, integer, []}]}]}}], Spec),
    ?assertEqual({error, invalid_edoc_provenance},
                 'ldoc-beam':collect(
                   BeamPath, {edoc, SourcePath, [IncludeDir | improper]})),
    ?assertEqual({error, invalid_edoc_provenance},
                 'ldoc-beam':collect(BeamPath, {edoc, <<>>, []})),
    BinarySourcePath = list_to_binary(SourcePath),
    {ok, BinaryDeclared} = 'ldoc-beam':collect(
                             list_to_binary(BeamPath),
                             {edoc, BinarySourcePath, []}),
    ?assertEqual(#{tool => edoc, source_path => BinarySourcePath,
                   include_paths => [], evidence => caller_declared},
                 maps:get(conversion, maps:get(source, BinaryDeclared))),
    {ok, DeclaredOnly} = 'ldoc-beam':collect(
                           BeamPath, {edoc, "not-inspected.erl", []}),
    ?assertEqual(#{tool => edoc, source_path => "not-inspected.erl",
                   include_paths => [], evidence => caller_declared},
                 maps:get(conversion, maps:get(source, DeclaredOnly))),
    {ok, ChunkBytes} = file:read_file(ChunkPath),
    #{beam_path => BeamPath, chunk_path => ChunkPath,
      chunk_bytes => ChunkBytes,
      source_path => SourcePath, include_dir => IncludeDir,
      module_beam => Beam, module => Plain}.

package_dirs(Temp, Name) ->
    Root = filename:join(Temp, Name),
    Ebin = filename:join(Root, "ebin"),
    Doc = filename:join(Root, "doc"),
    Chunks = filename:join(Doc, "chunks"),
    ok = filelib:ensure_dir(filename:join(Ebin, "placeholder")),
    ok = filelib:ensure_dir(filename:join(Chunks, "placeholder")),
    #{root => Root, ebin => Ebin, doc => Doc, chunks => Chunks}.

erl_s03_collect(Temp, Classic) ->
    Target = package_dirs(Temp, "target-package"),
    Decoy = package_dirs(Temp, "decoy-package"),
    Beam = maps:get(module_beam, Classic),
    TargetBeam = write_beam(maps:get(ebin, Target), "ldoc_classic.beam", Beam),
    DecoyBeam = write_beam(maps:get(ebin, Decoy), "ldoc_classic.beam", Beam),
    TargetChunk = maps:get(chunks, Target),
    DecoyChunk = maps:get(chunks, Decoy),
    TargetBytes = classic_sidecar(maps:get(chunk_bytes, Classic),
                                  #{<<"en">> => [{p, [], [<<"Target package.">>]}]}),
    DecoyBytes = classic_sidecar(maps:get(chunk_bytes, Classic),
                                 #{<<"en">> => [{p, [], [<<"Decoy package.">>]}]}),
    TargetSidecar = write_beam(TargetChunk, "ldoc_classic.chunk", TargetBytes),
    DecoySidecar = write_beam(DecoyChunk, "ldoc_classic.chunk", DecoyBytes),
    ?assertEqual(false, code:is_loaded(ldoc_classic)),
    true = code:add_patha(maps:get(ebin, Decoy)),
    {ok, OriginalCwd} = file:get_cwd(),
    try
        PathBefore = code:get_path(),
        BinaryTarget = list_to_binary(TargetBeam),
        {ok, BinaryResult} = 'ldoc-beam':collect(BinaryTarget),
        ?assertEqual(#{<<"en">> => [{p, [], [<<"Target package.">>]}]},
                     maps:get(doc, BinaryResult)),
        ?assertEqual(#{carrier => eep48_sidecar,
                       path => list_to_binary(filename:absname(TargetSidecar)),
                       beam_path => BinaryTarget},
                     maps:get(source, BinaryResult)),
        ?assertEqual(false, code:is_loaded(ldoc_classic)),
        ok = file:set_cwd(Temp),
        try
            RelativeTarget = filename:join(["target-package", "ebin",
                                            "ldoc_classic.beam"]),
            RelativeChunk = filename:join(["target-package", "doc", "chunks",
                                           "ldoc_classic.chunk"]),
            {ok, RelativeResult} = 'ldoc-beam':collect(RelativeTarget),
            ?assertEqual(#{<<"en">> => [{p, [], [<<"Target package.">>]}]},
                         maps:get(doc, RelativeResult)),
            ?assertEqual(#{carrier => eep48_sidecar,
                           path => filename:absname(RelativeChunk),
                           beam_path => RelativeTarget},
                         maps:get(source, RelativeResult))
        after
            ok = file:set_cwd(OriginalCwd)
        end,
        RenamedBeam = write_beam(maps:get(ebin, Target), "renamed.beam", Beam),
        {ok, RenamedResult} = 'ldoc-beam':collect(RenamedBeam),
        ?assertEqual(maps:get(doc, BinaryResult), maps:get(doc, RenamedResult)),
        ?assertEqual(#{carrier => eep48_sidecar,
                       path => filename:absname(TargetSidecar),
                       beam_path => RenamedBeam},
                     maps:get(source, RenamedResult)),
        NoPackageBeam = write_beam(Temp, "no-package.beam", Beam),
        ?assertEqual({error, missing_docs},
                     'ldoc-beam':collect(NoPackageBeam)),
        NoSidecar = package_dirs(Temp, "no-sidecar-package"),
        NoSidecarBeam = write_beam(maps:get(ebin, NoSidecar),
                                   "ldoc_classic.beam", Beam),
        ?assertEqual({error, missing_docs}, 'ldoc-beam':collect(NoSidecarBeam)),
        Ancestor = package_dirs(Temp, "ancestor-package"),
        AncestorBeam = write_beam(maps:get(ebin, Ancestor),
                                  "ldoc_classic.beam", Beam),
        AncestorChunks = filename:join([Temp, "doc", "chunks"]),
        ok = filelib:ensure_dir(filename:join(AncestorChunks, "placeholder")),
        _ = write_beam(AncestorChunks, "ldoc_classic.chunk", TargetBytes),
        ?assertEqual({error, missing_docs},
                     'ldoc-beam':collect(AncestorBeam)),
        RedirectSidecar = package_dirs(Temp, "redirect-sidecar-package"),
        RedirectSidecarBeam = write_beam(maps:get(ebin, RedirectSidecar),
                                         "ldoc_classic.beam", Beam),
        RedirectLink = filename:join(maps:get(chunks, RedirectSidecar),
                                     "ldoc_classic.chunk"),
        ok = file:make_symlink(DecoySidecar, RedirectLink),
        ?assertEqual({error, invalid_sidecar_association},
                     'ldoc-beam':collect(RedirectSidecarBeam)),
        RedirectBeamPackage = package_dirs(Temp, "redirect-beam-package"),
        RedirectBeam = filename:join(maps:get(ebin, RedirectBeamPackage),
                                     "ldoc_classic.beam"),
        ok = file:make_symlink(DecoyBeam, RedirectBeam),
        _ = write_beam(maps:get(chunks, RedirectBeamPackage),
                       "ldoc_classic.chunk", TargetBytes),
        ?assertEqual({error, invalid_sidecar_association},
                     'ldoc-beam':collect(RedirectBeam)),
        ?assertEqual(PathBefore, code:get_path()),
        ?assertEqual(false, code:is_loaded(ldoc_classic))
    after
        true = code:del_path(maps:get(ebin, Decoy))
    end.

erl_s04_collect(Temp, LfeBeam) ->
    DocsTerm = docs_term(LfeBeam),
    SidecarBytes = replace_module_doc_bytes(
                     LfeBeam,
                     #{<<"en">> => <<"Sidecar must lose.">>}),
    Embedded = package_dirs(Temp, "embedded-precedence-package"),
    EmbeddedBeam = write_beam(maps:get(ebin, Embedded),
                              "ldoc-fixture.beam", LfeBeam),
    _ = write_beam(maps:get(chunks, Embedded),
                   "ldoc-fixture.chunk", SidecarBytes),
    {ok, EmbeddedResult} = 'ldoc-beam':collect(EmbeddedBeam),
    {ok, ReadResult} = 'ldoc-beam':'read-docs'(EmbeddedBeam),
    ?assertEqual(ReadResult, EmbeddedResult),
    ?assertEqual(#{<<"en">> => <<"Fixture module.">>},
                 maps:get(doc, EmbeddedResult)),
    HiddenBeam = replace_docs(
                   LfeBeam,
                   term_to_binary(setelement(5, DocsTerm, hidden))),
    HiddenPath = write_beam(maps:get(ebin, Embedded), "hidden.beam", HiddenBeam),
    {ok, HiddenResult} = 'ldoc-beam':collect(HiddenPath),
    ?assertEqual(hidden, maps:get(doc, HiddenResult)),
    NoneBeam = replace_docs(LfeBeam,
                            term_to_binary(setelement(5, DocsTerm, none))),
    NonePath = write_beam(maps:get(ebin, Embedded), "none.beam", NoneBeam),
    {ok, NoneResult} = 'ldoc-beam':collect(NonePath),
    ?assertEqual(none, maps:get(doc, NoneResult)),
    CorruptEmbedded = replace_docs(LfeBeam, <<1, 2, 3>>),
    CorruptEmbeddedPath = write_beam(maps:get(ebin, Embedded),
                                     "corrupt-embedded.beam", CorruptEmbedded),
    ?assertEqual({error, invalid_docs},
                 'ldoc-beam':collect(CorruptEmbeddedPath)),
    MissingBeam = remove_chunk(LfeBeam, "Docs"),
    MissingPackage = package_dirs(Temp, "sidecar-fallback-package"),
    MissingPath = write_beam(maps:get(ebin, MissingPackage),
                             "ldoc-fixture.beam", MissingBeam),
    SidecarPath = write_beam(maps:get(chunks, MissingPackage),
                             "ldoc-fixture.chunk", SidecarBytes),
    ?assertEqual({error, missing_docs}, 'ldoc-beam':'read-docs'(MissingPath)),
    {ok, SidecarResult} = 'ldoc-beam':collect(MissingPath),
    ?assertEqual(#{<<"en">> => <<"Sidecar must lose.">>},
                 maps:get(doc, SidecarResult)),
    ?assertEqual(#{carrier => eep48_sidecar,
                   path => filename:absname(SidecarPath),
                   beam_path => MissingPath}, maps:get(source, SidecarResult)),
    CorruptSidecarPackage = package_dirs(Temp, "corrupt-sidecar-package"),
    CorruptSidecarBeam = write_beam(maps:get(ebin, CorruptSidecarPackage),
                                    "ldoc-fixture.beam", MissingBeam),
    _ = write_beam(maps:get(chunks, CorruptSidecarPackage),
                   "ldoc-fixture.chunk", <<1, 2, 3>>),
    ?assertEqual({error, invalid_docs},
                 'ldoc-beam':collect(CorruptSidecarBeam)),
    UnreadablePackage = package_dirs(Temp, "unreadable-sidecar-package"),
    UnreadableBeam = write_beam(maps:get(ebin, UnreadablePackage),
                                "ldoc-fixture.beam", MissingBeam),
    UnreadablePath = filename:join(maps:get(chunks, UnreadablePackage),
                                   "ldoc-fixture.chunk"),
    ok = file:make_dir(UnreadablePath),
    {error, UnreadableReason} = file:read_file(UnreadablePath),
    ?assertEqual({error, {read_sidecar, UnreadableReason}},
                 'ldoc-beam':collect(UnreadableBeam)),
    AbsentPackage = package_dirs(Temp, "absent-sidecar-package"),
    AbsentBeam = write_beam(maps:get(ebin, AbsentPackage),
                            "ldoc-fixture.beam", MissingBeam),
    ?assertEqual({error, missing_docs}, 'ldoc-beam':collect(AbsentBeam)).

ldo_s01(LegacyPath) ->
    ?assertEqual({error, missing_docs}, 'ldoc-beam':'read-docs'(LegacyPath)),
    {ok, Module} = 'ldoc-beam':collect(LegacyPath),
    ?assertEqual(#{carrier => embedded_beam,
                   path => LegacyPath,
                   chunk => <<"LDoc">>,
                   legacy_version => lfe_docs_v1,
                   format_policy => lodox_markdown},
                 maps:get(source, Module)),
    ?assertEqual(<<"ldoc-legacy">>, maps:get(name, Module)),
    ?assertEqual(<<"lfe">>, maps:get(language, Module)),
    ?assertEqual(<<"text/markdown">>, maps:get(format, Module)),
    ?assertEqual(undefined, maps:get(annotation, Module)),
    ?assertEqual(#{<<"und">> =>
                   <<"Classic module.\n\nSecond paragraph.">>},
                 maps:get(doc, Module)),
    ?assertEqual(#{legacy_doc_lines =>
                   [<<"Classic module.">>, <<>>, <<"Second paragraph.">>]},
                 maps:get(metadata, Module)),
    Entries = maps:get(entries, Module),
    ?assertEqual(
       [{<<"function">>, <<"bare">>, 0},
        {<<"function">>, <<"shape">>, 1},
        {<<"function">>, <<"shape">>, 2},
        {<<"macro">>, <<"direct">>, unknown},
        {<<"macro">>, <<"show">>, unknown}],
       entry_keys(Entries)),
    ?assertEqual(false,
                 lists:any(fun(E) -> maps:get(name, E) =:= <<"private-helper">> end,
                           Entries)),
    assert_legacy_entry(Entries, <<"function">>, <<"bare">>, 0, 17,
                        [{[], []}], none, []),
    assert_legacy_entry(Entries, <<"function">>, <<"shape">>, 1, 8,
                        [{[x], [[is_integer, x]]}, {[x], []}],
                        #{<<"und">> => <<"One classic argument.">>},
                        [<<"One classic argument.">>]),
    assert_legacy_entry(Entries, <<"function">>, <<"shape">>, 2, 13,
                        [{[x, y], []}],
                        #{<<"und">> => <<"Two classic arguments.">>},
                        [<<"Two classic arguments.">>]),
    assert_legacy_entry(Entries, <<"macro">>, <<"direct">>, unknown, 26,
                        [args], #{<<"und">> => <<"Classic direct macro.">>},
                        [<<"Classic direct macro.">>]),
    assert_legacy_entry(Entries, <<"macro">>, <<"show">>, unknown, 21,
                        [{[x], [[is_atom, x]]}, {[x], []}],
                        #{<<"und">> => <<"Classic guarded macro.">>},
                        [<<"Classic guarded macro.">>]).

ldo_s02(Temp, LegacyBeam) ->
    {ok, {_, [{"LDoc", LegacyBytes}]}} = beam_lib:chunks(LegacyBeam, ["LDoc"]),
    LegacyTerm = binary_to_term(LegacyBytes),
    Corrupt = write_beam(Temp, "legacy-corrupt.beam",
                         replace_chunk(LegacyBeam, "LDoc", <<1, 2, 3>>)),
    ?assertEqual({error, invalid_ldoc}, 'ldoc-beam':collect(Corrupt)),
    TrailingBytes = <<LegacyBytes/binary, 0>>,
    Trailing = write_beam(Temp, "legacy-trailing.beam",
                          replace_chunk(LegacyBeam, "LDoc", TrailingBytes)),
    ?assertEqual({error, invalid_ldoc}, 'ldoc-beam':collect(Trailing)),
    WrongVersion = write_beam(
                     Temp, "legacy-wrong-version.beam",
                     replace_chunk(LegacyBeam, "LDoc",
                                   term_to_binary(setelement(1, LegacyTerm,
                                                             not_lfe_docs_v1)))),
    ?assertEqual({error, invalid_ldoc}, 'ldoc-beam':collect(WrongVersion)),
    [First | Rest] = element(2, LegacyTerm),
    MalformedEntry = write_beam(
                       Temp, "legacy-malformed-entry.beam",
                       replace_chunk(LegacyBeam, "LDoc",
                                     term_to_binary(setelement(
                                                      2, LegacyTerm,
                                                      [malformed | Rest])))),
    ?assertEqual({error, invalid_ldoc}, 'ldoc-beam':collect(MalformedEntry)),
    BadArity = list_to_tuple(lists:sublist(tuple_to_list(First), 6)),
    BadArityPath = write_beam(
                     Temp, "legacy-bad-entry-arity.beam",
                     replace_chunk(LegacyBeam, "LDoc",
                                   term_to_binary(setelement(
                                                    2, LegacyTerm,
                                                    [BadArity | Rest])))),
    ?assertEqual({error, invalid_ldoc}, 'ldoc-beam':collect(BadArityPath)),
    Duplicate = write_beam(
                  Temp, "legacy-duplicate.beam",
                  replace_chunk(LegacyBeam, "LDoc",
                                term_to_binary(setelement(2, LegacyTerm,
                                                          [First, First])))),
    ?assertEqual({error, invalid_ldoc}, 'ldoc-beam':collect(Duplicate)),
    Removed = write_beam(Temp, "legacy-removed.beam",
                         remove_chunk(LegacyBeam, "LDoc")),
    ?assertEqual({error, missing_docs}, 'ldoc-beam':collect(Removed)).

ldo_s03_collect(Temp, LfePath, ErlPath, Classic, LegacyBeam) ->
    LegacyPath = write_beam(Temp, "legacy-projection.beam", LegacyBeam),
    {ok, Lfe} = 'ldoc-beam':collect(LfePath),
    {ok, Erlang} = 'ldoc-beam':collect(ErlPath),
    EDoc = maps:get(module, Classic),
    {ok, Legacy} = 'ldoc-beam':collect(LegacyPath),
    ?assertEqual(
       #{carrier => embedded_beam,
         name => <<"ldoc-fixture">>, language => <<"lfe">>,
         entries => [
          {{<<"function">>, <<"LFE-EXPAND-EXPORTED-MACRO">>, 3}, none, internal},
          {{<<"function">>, <<"bare">>, 0}, none, candidate},
          {{<<"function">>, <<"sample">>, 1},
           #{<<"en">> => <<"One argument.">>}, candidate},
          {{<<"function">>, <<"sample">>, 2},
           #{<<"en">> => <<"Two arguments.">>}, candidate},
          {{<<"macro">>, <<"show">>, 1},
           #{<<"en">> => <<"Display one argument.">>}, candidate}]},
       consumer_projection(Lfe)),
    ?assertEqual(
       #{carrier => embedded_beam,
         name => <<"ldoc_modern">>, language => <<"erlang">>,
         entries => [
          {{<<"callback">>, <<"get">>, 0},
           #{<<"en">> => <<"Get a value.">>}, candidate},
          {{<<"function">>, <<"hidden">>, 0}, hidden, candidate},
          {{<<"function">>, <<"show">>, 1},
           #{<<"en">> => <<"Show one value.">>}, candidate},
          {{<<"type">>, <<"value">>, 0},
           #{<<"en">> => <<"A fixture value type.">>}, candidate}]},
       consumer_projection(Erlang)),
    ?assertEqual(
       #{carrier => eep48_sidecar,
         name => <<"ldoc_classic">>, language => <<"erlang">>,
         entries => [
          {{<<"function">>, <<"show">>, 1},
           #{<<"en">> => [{p, [], [<<"Show the input.">>]}]}, candidate}]},
       consumer_projection(EDoc)),
    ?assertEqual(
       #{carrier => embedded_beam,
         name => <<"ldoc-legacy">>, language => <<"lfe">>,
         entries => [
          {{<<"function">>, <<"bare">>, 0}, none, candidate},
          {{<<"function">>, <<"shape">>, 1},
           #{<<"und">> => <<"One classic argument.">>}, candidate},
          {{<<"function">>, <<"shape">>, 2},
           #{<<"und">> => <<"Two classic arguments.">>}, candidate},
          {{<<"macro">>, <<"direct">>, unknown},
           #{<<"und">> => <<"Classic direct macro.">>}, candidate},
          {{<<"macro">>, <<"show">>, unknown},
           #{<<"und">> => <<"Classic guarded macro.">>}, candidate}]},
       consumer_projection(Legacy)),
    ?assertEqual(#{carrier => embedded_beam,
                   path => LegacyPath, chunk => <<"LDoc">>,
                   legacy_version => lfe_docs_v1,
                   format_policy => lodox_markdown}, maps:get(source, Legacy)),

    Package = package_dirs(Temp, "legacy-composition"),
    Ebin = maps:get(ebin, Package),
    Chunks = maps:get(chunks, Package),
    {ok, LfeBeam} = file:read_file(LfePath),
    DocsTerm = docs_term(LfeBeam),
    EmbeddedBytes = term_to_binary(
                      setelement(5, DocsTerm,
                                 #{<<"en">> => <<"Embedded docs win.">>})),
    EmbeddedBeam = replace_chunk(LegacyBeam, "Docs", EmbeddedBytes),
    EmbeddedPath = write_beam(Ebin, "ldoc-legacy.beam", EmbeddedBeam),
    SidecarBytes = classic_sidecar(
                     maps:get(chunk_bytes, Classic),
                     #{<<"en">> => [{p, [], [<<"Sidecar wins.">>]}]}),
    _ = write_beam(Chunks, "ldoc-legacy.chunk", SidecarBytes),
    {ok, EmbeddedResult} = 'ldoc-beam':collect(EmbeddedPath),
    ?assertEqual(#{<<"en">> => <<"Embedded docs win.">>},
                 maps:get(doc, EmbeddedResult)),
    ?assertEqual(embedded_beam,
                 maps:get(carrier, maps:get(source, EmbeddedResult))),
    HiddenPath = write_beam(
                   Ebin, "hidden.beam",
                   replace_chunk(LegacyBeam, "Docs",
                                 term_to_binary(setelement(5, DocsTerm, hidden)))),
    {ok, HiddenResult} = 'ldoc-beam':collect(HiddenPath),
    ?assertEqual(hidden, maps:get(doc, HiddenResult)),
    BadEmbeddedPath = write_beam(
                        Ebin, "bad-embedded.beam",
                        replace_chunk(LegacyBeam, "Docs", <<1, 2, 3>>)),
    ?assertEqual({error, invalid_docs}, 'ldoc-beam':collect(BadEmbeddedPath)),

    NoDocsPath = write_beam(Ebin, "ldoc-legacy.beam", LegacyBeam),
    {ok, SidecarResult} = 'ldoc-beam':collect(NoDocsPath),
    ?assertEqual(#{<<"en">> => [{p, [], [<<"Sidecar wins.">>]}]},
                 maps:get(doc, SidecarResult)),
    ?assertEqual(eep48_sidecar,
                 maps:get(carrier, maps:get(source, SidecarResult))),
    CorruptSidecarPackage = package_dirs(Temp, "legacy-corrupt-sidecar"),
    CorruptSidecarBeam = write_beam(maps:get(ebin, CorruptSidecarPackage),
                                    "ldoc-legacy.beam", LegacyBeam),
    _ = write_beam(maps:get(chunks, CorruptSidecarPackage),
                   "ldoc-legacy.chunk", <<1, 2, 3>>),
    ?assertEqual({error, invalid_docs},
                 'ldoc-beam':collect(CorruptSidecarBeam)),
    UnreadablePackage = package_dirs(Temp, "legacy-unreadable-sidecar"),
    UnreadableBeam = write_beam(maps:get(ebin, UnreadablePackage),
                                "ldoc-legacy.beam", LegacyBeam),
    UnreadableSidecar = filename:join(maps:get(chunks, UnreadablePackage),
                                      "ldoc-legacy.chunk"),
    ok = file:make_dir(UnreadableSidecar),
    {error, UnreadableReason} = file:read_file(UnreadableSidecar),
    ?assertEqual({error, {read_sidecar, UnreadableReason}},
                 'ldoc-beam':collect(UnreadableBeam)),
    DecoyPackage = package_dirs(Temp, "legacy-decoy-sidecar"),
    DecoySidecar = write_beam(maps:get(chunks, DecoyPackage),
                              "ldoc-legacy.chunk", SidecarBytes),
    RedirectPackage = package_dirs(Temp, "legacy-redirected-sidecar"),
    RedirectBeam = write_beam(maps:get(ebin, RedirectPackage),
                              "ldoc-legacy.beam", LegacyBeam),
    RedirectPath = filename:join(maps:get(chunks, RedirectPackage),
                                 "ldoc-legacy.chunk"),
    ok = file:make_symlink(DecoySidecar, RedirectPath),
    ?assertEqual({error, invalid_sidecar_association},
                 'ldoc-beam':collect(RedirectBeam)),
    AbsentPackage = package_dirs(Temp, "legacy-absent-sidecar"),
    AbsentBeam = write_beam(maps:get(ebin, AbsentPackage),
                            "ldoc-legacy.beam", LegacyBeam),
    {ok, LegacyResult} = 'ldoc-beam':collect(AbsentBeam),
    ?assertEqual(consumer_projection(Legacy),
                 consumer_projection(LegacyResult)),
    ?assertEqual(lfe_docs_v1,
                 maps:get(legacy_version, maps:get(source, LegacyResult))),
    NoDocsNoLegacy = remove_chunk(LegacyBeam, "LDoc"),
    AbsentAllPackage = package_dirs(Temp, "legacy-absent-all"),
    AbsentAllBeam = write_beam(maps:get(ebin, AbsentAllPackage),
                               "ldoc-legacy.beam", NoDocsNoLegacy),
    ?assertEqual({error, missing_docs}, 'ldoc-beam':collect(AbsentAllBeam)).

classic_sidecar(ChunkBytes, ModuleDoc) ->
    Term = binary_to_term(ChunkBytes),
    term_to_binary(setelement(5, Term, ModuleDoc)).

replace_module_doc_bytes(Beam, ModuleDoc) ->
    term_to_binary(setelement(5, docs_term(Beam), ModuleDoc)).

entry_keys(Entries) ->
    [{maps:get(kind, E), maps:get(name, E), maps:get(arity, E)} || E <- Entries].

assert_entry(Entries, Kind, Name, Arity, Line, Signatures, Doc, Visibility) ->
    Entry = entry(Entries, Kind, Name, Arity),
    ?assertEqual(Line, erl_anno:line(maps:get(annotation, Entry))),
    ?assertEqual(Signatures, maps:get(signatures, Entry)),
    ?assertEqual(Doc, maps:get(doc, Entry)),
    ?assertEqual(Visibility, maps:get(visibility, Entry)),
    ?assert(is_map(maps:get(metadata, Entry))).

assert_legacy_entry(Entries, Kind, Name, Arity, Line, Patterns, Doc,
                    DocLines) ->
    Entry = entry(Entries, Kind, Name, Arity),
    ?assertEqual(Line, erl_anno:line(maps:get(annotation, Entry))),
    ?assertEqual([], maps:get(signatures, Entry)),
    ?assertEqual(Patterns, maps:get(patterns, Entry)),
    ?assertEqual(Doc, maps:get(doc, Entry)),
    ?assertEqual(candidate, maps:get(visibility, Entry)),
    ?assertEqual(#{legacy_doc_lines => DocLines, legacy_exported => true},
                 maps:get(metadata, Entry)).

entry(Entries, Kind, Name, Arity) ->
    [Entry] = [E || E <- Entries,
                    maps:get(kind, E) =:= Kind,
                    maps:get(name, E) =:= Name,
                    maps:get(arity, E) =:= Arity],
    Entry.

entry_doc(Entries, Kind, Name, Arity) ->
    maps:get(doc, entry(Entries, Kind, Name, Arity)).

write_beam(Directory, Name, Beam) ->
    Path = filename:join(Directory, Name),
    ok = file:write_file(Path, Beam),
    Path.

docs_term(Beam) ->
    {ok, {_, [{"Docs", Bytes}]}} = beam_lib:chunks(Beam, ["Docs"]),
    binary_to_term(Bytes).

replace_doc(Beam, Identity, Doc) ->
    Term = docs_term(Beam),
    Entries = [case element(1, Entry) of
                   Identity -> setelement(4, Entry, Doc);
                   _ -> Entry
               end || Entry <- element(7, Term)],
    replace_docs(Beam, term_to_binary(setelement(7, Term, Entries))).

replace_format_and_doc(Beam, Format, Identity, Doc) ->
    Term = docs_term(Beam),
    Entries = [case element(1, Entry) of
                   Identity -> setelement(4, Entry, Doc);
                   _ -> Entry
               end || Entry <- element(7, Term)],
    WithDocs = setelement(7, Term, Entries),
    replace_docs(Beam, term_to_binary(setelement(4, WithDocs, Format))).

replace_docs(Beam, DocsBytes) ->
    replace_chunk(Beam, "Docs", DocsBytes).

replace_chunk(Beam, Name, ChunkBytes) ->
    {ok, _, Chunks} = beam_lib:all_chunks(Beam),
    WithoutChunk = [Chunk || Chunk = {ChunkName, _} <- Chunks,
                             ChunkName =/= Name],
    {ok, NewBeam} = beam_lib:build_module([{Name, ChunkBytes} | WithoutChunk]),
    NewBeam.

remove_chunk(Beam, Name) ->
    {ok, _, Chunks} = beam_lib:all_chunks(Beam),
    {ok, NewBeam} = beam_lib:build_module(
                      [Chunk || Chunk = {ChunkName, _} <- Chunks,
                                ChunkName =/= Name]),
    NewBeam.
