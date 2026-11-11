-module(ldoc_beam_tests).

-include_lib("eunit/include/eunit.hrl").

ldoc_beam_test_() ->
    {setup, fun setup/0, fun cleanup/1,
     fun(Temp) -> {timeout, 120, ?_test(run(Temp))} end}.

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
    ldo_s03_collect(Temp, LfePath, ErlPath, Classic, LegacyBeam),
    mix_s01_s04(Temp, LfePath, ErlPath, Classic, LegacyBeamPath),
    store_s01_s06(Temp, LfePath, ErlPath, Classic, LegacyBeamPath).

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

mix_s01_s04(Temp, LfePath, ErlPath, Classic, LegacyPath) ->
    Release = #{namespace => <<"local">>, package => <<"beam-fixtures">>,
                version => <<"2.0-rc1">>},
    EdocPath = maps:get(beam_path, Classic),
    SourcePath = maps:get(source_path, Classic),
    IncludeDir = maps:get(include_dir, Classic),
    EdocInput = {EdocPath, {edoc, SourcePath, [IncludeDir]}},
    Inputs = [LegacyPath, EdocInput, ErlPath, LfePath],
    CodePathBefore = code:get_path(),
    FixtureLoadsBefore = fixture_loads(),
    {ok, Docset} = assemble_without_loading(Release, Inputs),
    {ok, DirectLfe} = 'ldoc-beam':collect(LfePath),
    {ok, DirectLegacy} = 'ldoc-beam':collect(LegacyPath),
    {ok, DirectErlang} = 'ldoc-beam':collect(ErlPath),
    {ok, DirectEdoc} = 'ldoc-beam':collect(
                         EdocPath, {edoc, SourcePath, [IncludeDir]}),
    ?assertEqual(CodePathBefore, code:get_path()),
    ?assertEqual(FixtureLoadsBefore, fixture_loads()),
    ?assertEqual(#{release => Release,
                   modules => [DirectLfe, DirectLegacy,
                               DirectEdoc, DirectErlang]},
                 Docset),
    Modules = maps:get(modules, Docset),
    ?assertEqual([<<"ldoc-fixture">>, <<"ldoc-legacy">>,
                  <<"ldoc_classic">>, <<"ldoc_modern">>],
                 [maps:get(name, Module) || Module <- Modules]),
    LfeModule = module_named(Modules, <<"ldoc-fixture">>),
    LfeEntries = maps:get(entries, LfeModule),
    ?assertEqual(<<"lfe">>, maps:get(language, LfeModule)),
    ?assertEqual(embedded_beam, maps:get(carrier, maps:get(source, LfeModule))),
    ?assertEqual(<<"Docs">>, maps:get(chunk, maps:get(source, LfeModule))),
    ?assertEqual(LfePath, maps:get(path, maps:get(source, LfeModule))),
    ?assertEqual(#{<<"en">> => <<"One argument.">>},
                 entry_doc(LfeEntries, <<"function">>, <<"sample">>, 1)),
    ?assertEqual(#{<<"en">> => <<"Two arguments.">>},
                 entry_doc(LfeEntries, <<"function">>, <<"sample">>, 2)),
    ?assertEqual(none, entry_doc(LfeEntries, <<"function">>, <<"bare">>, 0)),
    ?assertEqual(internal,
                 maps:get(visibility,
                          entry(LfeEntries, <<"function">>,
                                <<"LFE-EXPAND-EXPORTED-MACRO">>, 3))),
    ClassicModule = module_named(Modules, <<"ldoc_classic">>),
    ClassicSource = maps:get(source, ClassicModule),
    ClassicEntry = entry(maps:get(entries, ClassicModule), <<"function">>,
                         <<"show">>, 1),
    ?assertEqual(<<"erlang">>, maps:get(language, ClassicModule)),
    ?assertEqual(<<"application/erlang+html">>,
                 maps:get(format, ClassicModule)),
    ?assertEqual(eep48_sidecar, maps:get(carrier, ClassicSource)),
    ?assertEqual(EdocPath, maps:get(beam_path, ClassicSource)),
    ?assertEqual(filename:absname(maps:get(chunk_path, Classic)),
                 maps:get(path, ClassicSource)),
    ?assertEqual(#{<<"en">> => [{p, [], [<<"Show the input.">>]}]},
                 maps:get(doc, ClassicEntry)),
    ?assertEqual([<<"show(X)">>], maps:get(signatures, ClassicEntry)),
    ?assertMatch([{attribute, 6, spec,
                   {{show, 1}, [{type, 6, 'fun',
                                 [{type, 6, product,
                                   [{ann_type, 6,
                                     [{var, 6, 'X'},
                                      {type, 6, integer, []}]}]},
                                  {type, 6, integer, []}]}]}}],
                 maps:get(signature, maps:get(metadata, ClassicEntry))),
    ?assertEqual(#{tool => edoc, source_path => SourcePath,
                   include_paths => [IncludeDir], evidence => caller_declared},
                 maps:get(conversion, ClassicSource)),
    LegacyModule = module_named(Modules, <<"ldoc-legacy">>),
    LegacyEntries = maps:get(entries, LegacyModule),
    ?assertEqual(<<"lfe">>, maps:get(language, LegacyModule)),
    ?assertEqual(embedded_beam,
                 maps:get(carrier, maps:get(source, LegacyModule))),
    ?assertEqual(lfe_docs_v1,
                 maps:get(legacy_version, maps:get(source, LegacyModule))),
    ?assertEqual(lodox_markdown,
                 maps:get(format_policy, maps:get(source, LegacyModule))),
    ?assertEqual(#{<<"und">> => <<"Classic module.\n\nSecond paragraph.">>},
                 maps:get(doc, LegacyModule)),
    ?assertEqual([1, 2],
                 [maps:get(arity, E) || E <- LegacyEntries,
                                          maps:get(name, E) =:= <<"shape">>]),
    LegacyMacro = entry(LegacyEntries, <<"macro">>, <<"show">>, unknown),
    ?assertEqual([], maps:get(signatures, LegacyMacro)),
    ?assertEqual([{[x], [[is_atom, x]]}, {[x], []}],
                 maps:get(patterns, LegacyMacro)),
    ModernModule = module_named(Modules, <<"ldoc_modern">>),
    ModernEntries = maps:get(entries, ModernModule),
    ?assertEqual(<<"erlang">>, maps:get(language, ModernModule)),
    ?assertEqual(ErlPath, maps:get(path, maps:get(source, ModernModule))),
    ?assertEqual(embedded_beam,
                 maps:get(carrier, maps:get(source, ModernModule))),
    ?assertEqual(<<"Docs">>, maps:get(chunk, maps:get(source, ModernModule))),
    ?assertEqual(hidden,
                 entry_doc(ModernEntries, <<"function">>, <<"hidden">>, 0)),
    ?assertEqual(#{<<"en">> => <<"Get a value.">>},
                 entry_doc(ModernEntries, <<"callback">>, <<"get">>, 0)),
    ?assertEqual(#{<<"en">> => <<"A fixture value type.">>},
                 entry_doc(ModernEntries, <<"type">>, <<"value">>, 0)),
    ?assertEqual(CodePathBefore, code:get_path()),
    ?assertEqual(FixtureLoadsBefore, fixture_loads()),
    AppPath = code:where_is_file("ldoc.app"),
    {ok, [{application, ldoc, AppProperties}]} = file:consult(AppPath),
    ?assert(lists:member('ldoc-docset', proplists:get_value(modules,
                                                            AppProperties))),

    ReversedInputs = lists:reverse(Inputs),
    {ok, ReversedDocset} = assemble_without_loading(Release, ReversedInputs),
    ?assertEqual(Docset, ReversedDocset),
    OtherVersion = Release#{version := <<"v2.0+rc.1">>},
    {ok, OtherVersionDocset} = assemble_without_loading(OtherVersion, Inputs),
    ?assertEqual(Docset#{release := OtherVersion}, OtherVersionDocset),
    UnicodeRelease = Release#{namespace := <<"caf\xc3\xa9">>},
    {ok, UnicodeDocset} = assemble_without_loading(UnicodeRelease, Inputs),
    ?assertEqual(UnicodeRelease, maps:get(release, UnicodeDocset)),
    BinaryLfePath = list_to_binary(LfePath),
    {ok, BinaryCollected} = 'ldoc-beam':collect(BinaryLfePath),
    {ok, BinaryPathDocset} = assemble_without_loading(Release, [BinaryLfePath]),
    ?assertEqual(#{release => Release, modules => [BinaryCollected]},
                 BinaryPathDocset),

    ?assertEqual({error, invalid_release_key},
                 assemble_without_loading(#{namespace => <<"local">>,
                                             package => <<"beam-fixtures">>},
                                           malformed)),
    ?assertEqual({error, invalid_release_key},
                 assemble_without_loading(Release#{extra => true}, Inputs)),
    ?assertEqual({error, invalid_release_key},
                 assemble_without_loading(
                   #{ns => <<"local">>, package => <<"beam-fixtures">>,
                     version => <<"2.0-rc1">>}, Inputs)),
    ?assertEqual({error, invalid_release_key},
                 assemble_without_loading(Release#{version := 2}, Inputs)),
    ?assertEqual({error, invalid_release_key},
                 assemble_without_loading(Release#{version := <<>>}, Inputs)),
    ?assertEqual({error, invalid_release_key},
                 assemble_without_loading(Release#{version := <<255>>}, Inputs)),
    ?assertEqual({error, invalid_inputs}, assemble_without_loading(Release, [])),
    ?assertEqual({error, invalid_inputs},
                 assemble_without_loading(Release, not_a_list)),
    ?assertEqual({error, invalid_inputs},
                 assemble_without_loading(Release, [LfePath | improper])),
    ?assertEqual({error, invalid_inputs},
                 assemble_without_loading(Release, [{<<>>, invalid} | improper])),
    ?assertEqual({error, {invalid_input, 2}},
                 assemble_without_loading(Release, [LfePath, {<<>>, invalid}])),
    MissingPath = filename:join(Temp, "not-present.beam"),
    ?assertEqual({error, {invalid_input, 2}},
                 assemble_without_loading(Release, [MissingPath, {<<>>, invalid}])),
    {ok, LfeBeamBytes} = file:read_file(LfePath),
    AliasPath = write_beam(Temp, "ldoc-fixture-alias.beam", LfeBeamBytes),
    ?assertEqual({error, {duplicate_module, <<"ldoc-fixture">>,
                          LfePath, AliasPath}},
                 assemble_without_loading(Release, [LfePath, AliasPath])),
    ?assertEqual({error, {collect_failed, MissingPath, {read_beam, enoent}}},
                 assemble_without_loading(Release, [LfePath, MissingPath])),
    ?assertEqual({error, {collect_failed, EdocPath, invalid_edoc_provenance}},
                 assemble_without_loading(Release,
                                          [LfePath,
                                           {EdocPath, {edoc, <<>>, []}}])),
    ?assertEqual({error, {collect_failed, MissingPath, {read_beam, enoent}}},
                 assemble_without_loading(Release,
                                          [LfePath, MissingPath,
                                           {LfePath, invalid_provenance}])),
    ?assertEqual({error, {collect_failed, MissingPath, {read_beam, enoent}}},
                 assemble_without_loading(Release,
                                          [LfePath, MissingPath, AliasPath])).

store_s01_s06(Temp, LfePath, ErlPath, Classic, LegacyPath) ->
    Root = filename:join(Temp, "exact-release-store"),
    Release1 = #{namespace => <<"local">>, package => <<"beam-fixtures">>,
                 version => <<"1.0">>},
    Release2 = Release1#{version := <<"v1.0">>},
    EdocPath = maps:get(beam_path, Classic),
    Inputs = [LegacyPath,
              {EdocPath, {edoc, maps:get(source_path, Classic),
                          [maps:get(include_dir, Classic)]}},
              ErlPath, LfePath],
    {ok, Docset1} = assemble_without_loading(Release1, Inputs),
    {ok, Docset2} = assemble_without_loading(Release2, Inputs),
    ok = 'ldoc-store':put(Root, Docset1),
    ok = 'ldoc-store':put(Root, Docset2),
    ?assertEqual({ok, Docset1}, 'ldoc-store':get(Root, Release1)),
    ?assertEqual({ok, Docset2}, 'ldoc-store':get(Root, Release2)),
    store_producer_oracles(Root, Release1, Docset1),
    store_supported_edges(Temp, Release1),
    store_data_only_reader(Temp, Root, Release1, Release2, Docset1, Docset2),
    store_addressing(Temp, Inputs),
    store_retry_and_conflict(Root, Release1, Release2, Docset1, Docset2),
    store_invalid_inputs(Temp, Root, Release1, Docset1),
    store_corruption(Temp, Root, Release1, Release2, Docset1, Docset2),
    store_concurrency(Temp, Release1, Docset1),
    store_filesystem_failure(Temp, Root, Release1, Docset1),
    store_fresh_vm(Root, Release1, LfePath, ErlPath, EdocPath, LegacyPath),
    store_source_guarantees(Root, Release1, Docset1),
    analysis_s01_s05(Temp, Root, Inputs, Docset1, Docset2).

store_producer_oracles(Root, Release, Docset) ->
    Modules = maps:get(modules, Docset),
    Lfe = module_named(Modules, <<"ldoc-fixture">>),
    LfeEntries = maps:get(entries, Lfe),
    ?assertEqual(#{<<"en">> => <<"One argument.">>},
                 entry_doc(LfeEntries, <<"function">>, <<"sample">>, 1)),
    ?assertEqual(#{<<"en">> => <<"Two arguments.">>},
                 entry_doc(LfeEntries, <<"function">>, <<"sample">>, 2)),
    ?assertEqual(none,
                 entry_doc(LfeEntries, <<"function">>, <<"bare">>, 0)),
    ?assertEqual(internal,
                 maps:get(visibility,
                          entry(LfeEntries, <<"function">>,
                                <<"LFE-EXPAND-EXPORTED-MACRO">>, 3))),
    Classic = module_named(Modules, <<"ldoc_classic">>),
    ClassicEntry = entry(maps:get(entries, Classic), <<"function">>,
                         <<"show">>, 1),
    ?assertEqual(#{<<"en">> => [{p, [], [<<"Show the input.">>]}]},
                 maps:get(doc, ClassicEntry)),
    ?assertMatch([{attribute, 6, spec, _}],
                 maps:get(signature, maps:get(metadata, ClassicEntry))),
    ?assertEqual(7, erl_anno:line(maps:get(annotation, ClassicEntry))),
    ?assertEqual(filename:absname(maps:get(source_path,
                                           maps:get(conversion,
                                                    maps:get(source, Classic)))),
                 maps:get(source_path,
                          maps:get(conversion, maps:get(source, Classic)))),
    ?assertEqual(caller_declared,
                 maps:get(evidence, maps:get(conversion,
                                             maps:get(source, Classic)))),
    ?assertEqual(eep48_sidecar, maps:get(carrier, maps:get(source, Classic))),
    Legacy = module_named(Modules, <<"ldoc-legacy">>),
    LegacyMacro = entry(maps:get(entries, Legacy), <<"macro">>,
                        <<"show">>, unknown),
    ?assertEqual([{[x], [[is_atom, x]]}, {[x], []}],
                 maps:get(patterns, LegacyMacro)),
    ?assertEqual([], maps:get(signatures, LegacyMacro)),
    Modern = module_named(Modules, <<"ldoc_modern">>),
    ModernEntries = maps:get(entries, Modern),
    ?assertEqual(14,
                 erl_anno:line(maps:get(source_anno,
                                        maps:get(metadata,
                                                 entry(ModernEntries,
                                                       <<"function">>,
                                                       <<"show">>, 1))))),
    ?assertEqual(hidden,
                 entry_doc(ModernEntries, <<"function">>, <<"hidden">>, 0)),
    ?assertEqual(#{<<"en">> => <<"Get a value.">>},
                 entry_doc(ModernEntries, <<"callback">>, <<"get">>, 0)),
    ?assertEqual({ok, Docset},
                 'ldoc-store':get(Root, Release)),
    SnapshotPath = store_path(Root, Release),
    {ok, SnapshotBytes} = file:read_file(SnapshotPath),
    {ok, [Envelope]} = lfe_io:read_file(SnapshotPath),
    ?assertEqual(ldoc_snapshot, maps:get(format, Envelope)),
    ?assertEqual(1, maps:get(format_version, Envelope)),
    ?assertEqual(Docset, maps:get(docset, Envelope)),
    ?assert(is_list(unicode:characters_to_list(SnapshotBytes, utf8))),
    ?assertEqual($\n, binary:last(SnapshotBytes)).

store_addressing(Temp, Inputs) ->
    Root = filename:join(Temp, "addressing"),
    Base = #{namespace => <<"local">>, package => <<"beam-fixtures">>,
             version => <<"1.0">>},
    ?assertEqual("773D8E522E0E00630A089FE9173C31751D734AFF056BB80787BF8C64ABA241F2.lfe",
                 filename:basename(store_path(Root, Base))),
    Keys = [Base,
            Base#{namespace := <<"local/sub">>},
            Base#{package := <<"../beam-fixtures">>},
            Base#{package := <<"beam\\fixtures">>},
            Base#{namespace := <<"caf\xc3\xa9">>},
            Base#{package := binary:copy(<<"long">>, 90)},
            Base#{package := <<"Case">>},
            Base#{package := <<"case">>},
            Base#{namespace := <<"\xc3\xa9">>},
            Base#{namespace := <<"e\xcc\x81">>},
            Base#{version := <<"v1.0">>}],
    lists:foreach(
      fun(Key) ->
          {ok, Docset} = assemble_without_loading(Key, Inputs),
          ok = 'ldoc-store':put(Root, Docset),
          ?assertEqual({ok, Docset}, 'ldoc-store':get(Root, Key)),
          Name = filename:basename(store_path(Root, Key)),
          ?assertEqual(68, length(Name)),
          ?assertEqual(".lfe", lists:nthtail(64, Name)),
          ?assert(lists:all(fun(C) ->
                                (C >= $0 andalso C =< $9) orelse
                                (C >= $A andalso C =< $F)
                            end, lists:sublist(Name, 64)))
      end, Keys),
    Paths = [store_path(Root, Key) || Key <- Keys],
    ?assertEqual(length(Keys), length(lists:usort(Paths))),
    BinaryRoot = list_to_binary(filename:join(Temp, "binary-root")),
    {ok, BinaryRootDocset} = assemble_without_loading(Base, Inputs),
    ok = 'ldoc-store':put(BinaryRoot, BinaryRootDocset),
    ?assertEqual({ok, BinaryRootDocset}, 'ldoc-store':get(BinaryRoot, Base)),
    MissingRoot = filename:join(Temp, "never-created-store"),
    ?assertEqual({error, not_found}, 'ldoc-store':get(MissingRoot, Base)),
    ?assertEqual(false, filelib:is_dir(MissingRoot)),
    ?assertEqual({error, not_found},
                 'ldoc-store':get(Root, Base#{version := <<"missing">>})),
    ?assertEqual(false, filelib:is_dir(MissingRoot)).

store_supported_edges(Temp, Release) ->
    EdgeRelease = Release#{version := <<"edges">>},
    Text = <<"quote \" slash \\ line\n café">>,
    NumericKeys = #{1 => integer_key, 1.0 => float_key},
    SpecialKey = #{'__struct__' => <<"ordinary-map-value">>, field => true},
    SpecialAtomKey = #{'__struct__' => ordinary_type, field => 2},
    Docset = #{release => EdgeRelease,
               modules => [#{name => <<"edge-literals">>,
                             entries => [],
                             metadata => #{text => Text,
                                           bitstring => <<5:3>>,
                                           improper => [head | tail],
                                           numeric_keys => NumericKeys,
                                           special_key => SpecialKey,
                                           special_atom_key => SpecialAtomKey}}]},
    Root = filename:join(Temp, "literal-codec-edges"),
    ok = 'ldoc-store':put(Root, Docset),
    ?assertEqual({ok, Docset}, 'ldoc-store':get(Root, EdgeRelease)),
    {ok, [Envelope]} = lfe_io:read_file(store_path(Root, EdgeRelease)),
    ?assertEqual(Docset, maps:get(docset, Envelope)),
    Metadata = maps:get(metadata, hd(maps:get(modules, Docset))),
    ?assertEqual(integer_key, maps:get(1, maps:get(numeric_keys, Metadata))),
    ?assertEqual(float_key, maps:get(1.0, maps:get(numeric_keys, Metadata))),
    ?assertEqual(SpecialKey, maps:get(special_key, Metadata)),
    ?assertEqual(SpecialAtomKey, maps:get(special_atom_key, Metadata)).

store_data_only_reader(Temp, Root, Release, OtherRelease, Docset, OtherDocset) ->
    Path = store_path(Root, Release),
    {ok, OriginalBytes} = file:read_file(Path),
    Marker = store_reader_eval_marker,
    SnapshotPrefix = lists:concat(
                       ["#M(format ldoc_snapshot format_version 1 docset ",
                        "#M(release #M(namespace #\"local\" package ",
                        "#\"beam-fixtures\" version #\"1.0\") modules ",
                        "(#M(name #\"store-marker-fixture\" metadata ",
                        "#M(attack "]),
    SnapshotSuffix = ") entries ())))",
    ReaderEval = lists:concat(
                   ["#.(call \x27erlang \x27put ",
                    "\x27store_reader_eval_marker \x27executed)"]),
    ComputedBinary = lists:concat(
                       ["#B(((progn (call \x27erlang \x27put ",
                        "\x27store_reader_eval_marker \x27executed) 5) ",
                        "(size 3)))"]),
    ?assertMatch({ok, [_]}, lfe_io:read_string(ReaderEval)),
    ?assertEqual(executed, erase(Marker)),
    ?assertMatch({ok, [_]}, lfe_io:read_string(ComputedBinary)),
    ?assertEqual(executed, erase(Marker)),
    {ok, [Envelope]} = lfe_io:read_file(Path),
    ValidThenReaderEval = iolist_to_binary(
                            [lfe_io:prettyprint1(Envelope), "\n", ReaderEval]),
    BadSnapshots = [iolist_to_binary([SnapshotPrefix, ReaderEval,
                                      SnapshotSuffix]),
                    iolist_to_binary([SnapshotPrefix, ComputedBinary,
                                      SnapshotSuffix]),
                    ValidThenReaderEval],
    lists:foreach(
      fun(BadBytes) ->
          ok = file:write_file(Path, BadBytes),
          ?assertEqual(undefined, erase(Marker)),
          ?assertEqual({error, invalid_snapshot},
                       'ldoc-store':get(Root, Release)),
          ?assertEqual(undefined, get(Marker)),
          ?assertEqual(undefined, erase(Marker)),
          ?assertEqual({error, invalid_snapshot},
                       'ldoc-store':put(Root, Docset)),
          ?assertEqual(undefined, get(Marker)),
          ?assertEqual({ok, BadBytes}, file:read_file(Path)),
          ?assertEqual({ok, OtherDocset},
                       'ldoc-store':get(Root, OtherRelease))
      end, BadSnapshots),
    ok = file:write_file(Path, OriginalBytes),
    ?assertEqual({ok, Docset}, 'ldoc-store':get(Root, Release)),

    LiteralPath = filename:join(Temp, "literal-token-controls"),
    LiteralDocset = #{release => Release,
                      modules => [#{name => <<"literal-controls">>,
                                    entries => [],
                                    metadata => #{literal_eval_symbol =>
                                                    list_to_atom("#."),
                                                  literal_binary_symbol =>
                                                    list_to_atom("#B("),
                                                  quoted => [quote, foo],
                                                  backquoted => [backquote, bar],
                                                  comma => [comma, baz],
                                                  bytes => <<1, 2, 3>>,
                                                  partial_bits => <<5:3>>,
                                                  text =>
                                                    <<"literal #.(not executed); ",
                                                      "#B(3); café">>}}]},
    ok = 'ldoc-store':put(LiteralPath, LiteralDocset),
    ?assertEqual({ok, LiteralDocset},
                 'ldoc-store':get(LiteralPath, Release)),
    {ok, [LiteralEnvelope]} =
        lfe_io:read_file(store_path(LiteralPath, Release)),
    LiteralMetadata = maps:get(metadata,
                               hd(maps:get(modules,
                                           maps:get(docset, LiteralEnvelope)))),
    ?assertEqual(list_to_atom("#."), maps:get(literal_eval_symbol,
                                               LiteralMetadata)),
    ?assertEqual(list_to_atom("#B("), maps:get(literal_binary_symbol,
                                                LiteralMetadata)),
    ?assertEqual([quote, foo], maps:get(quoted, LiteralMetadata)),
    ?assertEqual([backquote, bar], maps:get(backquoted, LiteralMetadata)),
    ?assertEqual([comma, baz], maps:get(comma, LiteralMetadata)),
    ?assertEqual(undefined, get(Marker)),
    ReaderSyntaxBytes = iolist_to_binary(
                          ["#M(format ldoc_snapshot format_version 1 docset ",
                           "#M(release #M(namespace #\"local\" package ",
                           "#\"beam-fixtures\" version #\"1.0\") modules ",
                           "(#M(name #\"literal-token-syntax\" entries () ",
                           "metadata #M(eval_symbol |#.| ",
                           "binary_symbol |#B(| ",
                           "text #\"contains #.(not executed) and #B(3)\" ",
                           "quoted 'foo backquoted `bar comma ,baz)))))"]),
    ReaderSyntaxPath = store_path(LiteralPath, Release),
    ok = file:write_file(ReaderSyntaxPath, ReaderSyntaxBytes),
    ?assertEqual(
       {ok, #{release => Release,
              modules => [#{name => <<"literal-token-syntax">>,
                            entries => [],
                            metadata => #{eval_symbol => list_to_atom("#."),
                                          binary_symbol => list_to_atom("#B("),
                                          text => <<"contains #.(not executed) and #B(3)">>,
                                          quoted => [quote, foo],
                                          backquoted => [backquote, bar],
                                          comma => [comma, baz]}}]}},
       'ldoc-store':get(LiteralPath, Release)),
    ?assertEqual(undefined, get(Marker)).

store_retry_and_conflict(Root, Release1, Release2, Docset1, Docset2) ->
    Path1 = store_path(Root, Release1),
    {ok, OriginalBytes} = file:read_file(Path1),
    ok = 'ldoc-store':put(Root, Docset1),
    {ok, RetryBytes} = file:read_file(Path1),
    ?assertEqual(OriginalBytes, RetryBytes),
    {ok, [Envelope]} = lfe_io:read_file(Path1),
    Reformat = iolist_to_binary([";; readable equivalent\n",
                                 lfe_io:print1(Envelope), "\n\n"]),
    ok = file:write_file(Path1, Reformat),
    ?assertEqual({ok, Docset1}, 'ldoc-store':get(Root, Release1)),
    ok = 'ldoc-store':put(Root, Docset1),
    {ok, AfterReformatRetry} = file:read_file(Path1),
    ?assertEqual(Reformat, AfterReformatRetry),
    Changed = change_first_documented_body(Docset1),
    ?assertEqual({error, {release_conflict, Release1}},
                 'ldoc-store':put(Root, Changed)),
    {ok, AfterConflict} = file:read_file(Path1),
    ?assertEqual(Reformat, AfterConflict),
    ?assertEqual({ok, Docset1}, 'ldoc-store':get(Root, Release1)),
    ?assertEqual({ok, Docset2}, 'ldoc-store':get(Root, Release2)).

store_invalid_inputs(Temp, Root, Release, Docset) ->
    Absent = filename:join(Temp, "rejected-store-inputs"),
    {ok, ExistingBytes} = file:read_file(store_path(Root, Release)),
    Fun = fun() -> ok end,
    Ref = make_ref(),
    Port = open_port({spawn_executable, os:find_executable("true")}, []),
    try
        Unsupported = [Fun, self(), Port, Ref],
        lists:foreach(
          fun(Value) ->
              Bad = put_module_field(Docset, metadata,
                                     #{nested => [ok | #{key => Value}]}),
              ?assertEqual({error, unsupported_snapshot_term},
                           'ldoc-store':put(Absent, Bad)),
              ?assertEqual(false, filelib:is_dir(Absent)),
              ?assertEqual({error, unsupported_snapshot_term},
                           'ldoc-store':put(Root, Bad)),
              ?assertEqual(ExistingBytes,
                           element(2, file:read_file(store_path(Root, Release))))
          end, Unsupported),
        ?assertEqual({error, invalid_docset},
                     'ldoc-store':put(Absent, #{release => Release,
                                                modules => []})),
        ?assertEqual({error, invalid_docset},
                     'ldoc-store':put(Absent, Docset#{extra => true})),
        ?assertEqual({error, invalid_docset},
                     'ldoc-store':put(Absent,
                                      Docset#{modules := [#{name => <<>>}]})),
        [FirstModule | _RestModules] = maps:get(modules, Docset),
        ?assertEqual({error, invalid_docset},
                     'ldoc-store':put(Absent,
                                      Docset#{modules := [FirstModule |
                                                          improper_tail]})),
        ?assertEqual({error, invalid_docset},
                     'ldoc-store':put(Absent,
                                      Docset#{modules := lists:reverse(
                                                          maps:get(modules,
                                                                   Docset))})),
        ?assertEqual({error, invalid_release_key},
                     'ldoc-store':put(Absent,
                                      Docset#{release := Release#{version := 2}})),
        ?assertEqual({error, invalid_store_root},
                     'ldoc-store':put(<<>>, Docset)),
        ?assertEqual({error, invalid_docset},
                     'ldoc-store':put(Absent, Docset#{modules := []})),
        ?assertEqual(false, filelib:is_dir(Absent)),
        ?assertEqual({error, invalid_store_root}, 'ldoc-store':get(<<>>, Release)),
        ?assertEqual({error, invalid_release_key},
                     'ldoc-store':get(Absent, Release#{version := <<>>}))
    after
        _ = port_close(Port)
    end,
    ?assertEqual(ExistingBytes,
                 element(2, file:read_file(store_path(Root, Release)))).

store_corruption(Temp, Root, Release, OtherRelease, Docset, OtherDocset) ->
    Path = store_path(Root, Release),
    OtherPath = store_path(Root, OtherRelease),
    {ok, GoodBytes} = file:read_file(Path),
    BadBodies = [<<255>>, <<"#M(format">>, <<>>, <<GoodBytes/binary, "\n#()\n">>,
                 <<"#M(wrong header).\n">>,
                 iolist_to_binary(lfe_io:prettyprint1(
                                    #{format => ldoc_snapshot,
                                      format_version => 1,
                                      docset => #{release => Release,
                                                  modules => []}}))],
    lists:foreach(
      fun(Bytes) ->
          ok = file:write_file(Path, Bytes),
          ?assertEqual({error, invalid_snapshot},
                       'ldoc-store':get(Root, Release)),
          ?assertEqual({error, invalid_snapshot},
                       'ldoc-store':put(Root, Docset)),
          ?assertEqual({ok, Bytes}, file:read_file(Path)),
          ?assertEqual({ok, OtherDocset},
                       'ldoc-store':get(Root, OtherRelease))
      end, BadBodies),
    Unsupported = iolist_to_binary(lfe_io:prettyprint1(
                                     #{format => ldoc_snapshot,
                                       format_version => 23,
                                       docset => invalid_body})),
    ok = file:write_file(Path, Unsupported),
    ?assertEqual({error, {unsupported_snapshot_version, 23}},
                 'ldoc-store':get(Root, Release)),
    ?assertEqual({error, {unsupported_snapshot_version, 23}},
                 'ldoc-store':put(Root, Docset)),
    ?assertEqual({ok, Unsupported}, file:read_file(Path)),
    MismatchBytes = iolist_to_binary([lfe_io:prettyprint1(
                                       #{format => ldoc_snapshot,
                                         format_version => 1,
                                         docset => OtherDocset}), "\n"]),
    ok = file:write_file(Path, MismatchBytes),
    ?assertEqual({error, {release_mismatch, Release, OtherRelease}},
                 'ldoc-store':get(Root, Release)),
    ?assertEqual({error, {release_mismatch, Release, OtherRelease}},
                 'ldoc-store':put(Root, Docset)),
    ?assertEqual({ok, MismatchBytes}, file:read_file(Path)),
    ok = file:delete(Path),
    ok = file:make_dir(Path),
    ?assertEqual({error, invalid_snapshot}, 'ldoc-store':get(Root, Release)),
    ?assertEqual({error, invalid_snapshot}, 'ldoc-store':put(Root, Docset)),
    ?assert(filelib:is_dir(Path)),
    ok = file:del_dir(Path),
    ok = file:write_file(Path, GoodBytes),
    Symlink = filename:join(Temp, "snapshot-symlink"),
    ok = file:make_symlink(OtherPath, Symlink),
    ok = file:delete(Path),
    ok = file:make_symlink(Symlink, Path),
    ?assertEqual({error, invalid_snapshot}, 'ldoc-store':get(Root, Release)),
    ?assertEqual({error, invalid_snapshot}, 'ldoc-store':put(Root, Docset)),
    ?assertMatch({ok, _}, file:read_link(Path)),
    ok = file:delete(Path),
    ok = file:write_file(Path, GoodBytes),
    ?assertEqual({ok, Docset}, 'ldoc-store':get(Root, Release)).

put_module_field(Docset, Field, Value) ->
    [First | Rest] = maps:get(modules, Docset),
    Docset#{modules := [First#{Field => Value} | Rest]}.

change_first_documented_body(Docset) ->
    [First | Rest] = maps:get(modules, Docset),
    Entries = maps:get(entries, First),
    ChangedEntries =
        [case {maps:get(kind, Entry), maps:get(name, Entry),
               maps:get(arity, Entry)} of
             {<<"function">>, <<"sample">>, 1} ->
                 Entry#{doc := #{<<"en">> => <<"Changed producer body.">>}};
             _ -> Entry
         end || Entry <- Entries],
    ChangedFirst = First#{entries := ChangedEntries},
    Docset#{modules := [ChangedFirst | Rest]}.

store_path(Root, Release) ->
    Namespace = maps:get(namespace, Release),
    Package = maps:get(package, Release),
    Version = maps:get(version, Release),
    Preimage = <<"ldoc-release-v1", 0,
                 (byte_size(Namespace)):64/unsigned-big, Namespace/binary,
                 (byte_size(Package)):64/unsigned-big, Package/binary,
                 (byte_size(Version)):64/unsigned-big, Version/binary>>,
    Digest = crypto:hash(sha256, Preimage),
    Hex = binary:encode_hex(Digest, uppercase),
    Child = case is_binary(Root) of
                true -> <<Hex/binary, ".lfe">>;
                false -> binary_to_list(Hex) ++ ".lfe"
            end,
    filename:join(Root, Child).

store_concurrency(Temp, Release, Docset) ->
    RootSame = filename:join(Temp, "concurrent-identical"),
    SameRef = make_ref(),
    SameWriters = [spawn_monitor(fun() ->
                                     await_and_put(Parent, SameRef, RootSame,
                                                   Docset)
                                 end) || Parent <- [self(), self()]],
    try
        await_writers(SameWriters, SameRef),
        ?assertEqual([ok, ok],
                     lists:sort(collect_writer_results(SameRef, 2, []))),
        await_writer_downs(SameWriters),
        ?assertEqual({ok, Docset}, 'ldoc-store':get(RootSame, Release))
    after
        cancel_monitored(SameWriters)
    end,
    store_different_concurrency(Temp, Release, Docset).

store_different_concurrency(Temp, Release, Docset) ->
    RootDifferent = filename:join(Temp, "concurrent-different"),
    OtherDocset = change_first_documented_body(Docset),
    DiffRef = make_ref(),
    Parent = self(),
    DiffWriters = [spawn_monitor(fun() ->
                                     await_and_put(Parent, DiffRef,
                                                   RootDifferent, Candidate)
                                 end) || Candidate <- [Docset, OtherDocset]],
    Reader = spawn_monitor(fun() ->
                               await_reader_go(Parent, RootDifferent, Release,
                                               Docset, OtherDocset)
                           end),
    try
        await_writer_readiness(DiffWriters, DiffRef),
        ReaderPid = element(1, Reader),
        receive {reader_ready, ReaderPid} -> ReaderPid ! reader_go
        after 30000 -> erlang:error(concurrent_reader_start_timeout)
        end,
        release_writers(DiffWriters, DiffRef),
        DiffResults = collect_writer_results(DiffRef, 2, []),
        await_writer_downs(DiffWriters),
        ?assertEqual(1, length([ok || ok <- DiffResults])),
        ?assertEqual(1, length([Key || {error, {release_conflict, Key}} <-
                                           DiffResults, Key =:= Release])),
        {ok, Winner} = 'ldoc-store':get(RootDifferent, Release),
        ?assert(Winner =:= Docset orelse Winner =:= OtherDocset),
        receive
            {reader_observations, ReaderPid, Observations} ->
                ?assertEqual(64, length(Observations)),
                ?assert(lists:all(fun(Observation) ->
                                      Observation =:= {error, not_found} orelse
                                      Observation =:= {ok, Docset} orelse
                                      Observation =:= {ok, OtherDocset}
                                  end, Observations))
        after 30000 ->
            erlang:error(concurrent_reader_timeout)
        end,
        await_monitor_normal(Reader)
    after
        cancel_monitored(DiffWriters ++ [Reader])
    end,
    PartialRoot = filename:join(Temp, "partial-temporary"),
    ok = filelib:ensure_dir(filename:join(PartialRoot, "placeholder")),
    Partial = filename:join(PartialRoot, ".ldoc-interrupted.tmp"),
    ok = file:write_file(Partial, <<"#M(format ldoc_snapshot">>),
    ?assertEqual({error, not_found}, 'ldoc-store':get(PartialRoot, Release)),
    ?assert(filelib:is_regular(Partial)),
    ok.

await_and_put(Parent, Ref, Root, Docset) ->
    Parent ! {writer_ready, Ref, self()},
    receive
        {writer_go, Ref} ->
            Result = 'ldoc-store':put(Root, Docset),
            Parent ! {writer_result, Ref, self(), Result}
    after 30000 ->
        erlang:error(writer_gate_timeout)
    end.

await_writers(Writers, Ref) ->
    await_writer_readiness(Writers, Ref),
    release_writers(Writers, Ref).

await_writer_readiness(Writers, Ref) ->
    lists:foreach(fun({Pid, _Monitor}) ->
                      receive {writer_ready, Ref, Pid} -> ok
                      after 30000 ->
                          erlang:error(concurrent_writer_start_timeout)
                      end
                  end, Writers).

release_writers(Writers, Ref) ->
    lists:foreach(fun({Pid, _Monitor}) -> Pid ! {writer_go, Ref} end, Writers).

await_writer_downs(Writers) ->
    lists:foreach(fun({Pid, Monitor}) ->
                      receive
                          {'DOWN', Monitor, process, Pid, normal} -> ok;
                          {'DOWN', Monitor, process, Pid, Reason} ->
                              erlang:error({concurrent_writer_crashed, Reason})
                      after 30000 ->
                          erlang:error(concurrent_writer_monitor_timeout)
                      end
                  end, Writers).

await_monitor_normal({Pid, Monitor}) ->
    receive
        {'DOWN', Monitor, process, Pid, normal} -> ok;
        {'DOWN', Monitor, process, Pid, Reason} ->
            erlang:error({concurrent_reader_crashed, Reason})
    after 30000 ->
        erlang:error(concurrent_reader_monitor_timeout)
    end.

cancel_monitored(Writers) ->
    lists:foreach(fun({Pid, Monitor}) ->
                      _ = exit(Pid, kill),
                      _ = erlang:demonitor(Monitor, [flush])
                  end, Writers).

collect_writer_results(_Ref, 0, Results) ->
    lists:reverse(Results);
collect_writer_results(Ref, Remaining, Results) ->
    receive
        {writer_result, Ref, _Pid, Result} ->
            collect_writer_results(Ref, Remaining - 1, [Result | Results]);
        {'DOWN', _Monitor, process, _Pid, Reason} when Reason =/= normal ->
            erlang:error({concurrent_writer_crashed, Reason})
    after 30000 ->
        erlang:error(concurrent_writer_timeout)
    end.

await_reader_go(Parent, Root, Release, Docset, OtherDocset) ->
    Parent ! {reader_ready, self()},
    receive
        reader_go ->
            Observations = [begin
                                Result = 'ldoc-store':get(Root, Release),
                                case Result =:= {error, not_found} orelse
                                     Result =:= {ok, Docset} orelse
                                     Result =:= {ok, OtherDocset} of
                                    true -> Result;
                                    false -> {invalid_observation, Result}
                                end
                            end || _ <- lists:seq(1, 64)],
            Parent ! {reader_observations, self(), Observations}
    after 30000 ->
        erlang:error(concurrent_reader_gate_timeout)
    end.

store_filesystem_failure(Temp, Root, Release, Docset) ->
    Blocker = filename:join(Temp, "store-root-is-a-file"),
    ok = file:write_file(Blocker, <<"root blocker">>),
    ?assertMatch({error, {store_io, _, _, _}},
                 'ldoc-store':put(Blocker, Docset)),
    ?assertMatch({error, {store_io, _, _, _}},
                 'ldoc-store':get(Blocker, Release)),
    ?assertEqual({ok, Docset}, 'ldoc-store':get(Root, Release)).

store_fresh_vm(Root, Release, LfePath, ErlPath, EdocPath, LegacyPath) ->
    Paths = [LfePath, ErlPath, EdocPath, LegacyPath],
    Parked = [{Path, Path ++ ".store-test-offline"} || Path <- Paths],
    lists:foreach(fun({Path, ParkedPath}) ->
                      ?assert(filelib:is_regular(Path)),
                      ok = file:rename(Path, ParkedPath)
                  end, Parked),
    try
        ?assert(lists:all(fun({_Path, ParkedPath}) ->
                              filelib:is_regular(ParkedPath)
                          end, Parked)),
        run_fresh_store_vm(Root, Release)
    after
        lists:foreach(fun({Path, ParkedPath}) ->
                          ok = file:rename(ParkedPath, Path)
                      end, Parked)
    end.

run_fresh_store_vm(Root, _Release) ->
    Erl = os:find_executable("erl"),
    Eval = "Root = hd(init:get_plain_arguments()), "
           "Release = #{namespace => <<\"local\">>, "
           "package => <<\"beam-fixtures\">>, version => <<\"1.0\">>}, "
           "{ok, _} = application:ensure_all_started(ldoc), "
           "{ok, Docset} = 'ldoc-store':get(Root, Release), "
           "Release = maps:get(release, Docset), "
           "[<<\"ldoc-fixture\">>, <<\"ldoc-legacy\">>, "
           "<<\"ldoc_classic\">>, <<\"ldoc_modern\">>] = "
           "[maps:get(name, M) || M <- maps:get(modules, Docset)], "
           "io:format(\"STORE_FRESH_VM_OK~n\"), halt(0).",
    CodePaths = lists:append([["-pa", Path] || Path <- code:get_path()]),
    Args = ["-noshell"] ++ CodePaths ++ ["-eval", Eval, "-extra", Root],
    Port = open_port({spawn_executable, Erl},
                     [{args, Args}, binary, exit_status, use_stdio,
                      stderr_to_stdout]),
    collect_fresh_vm(Port, []).

collect_fresh_vm(Port, Reversed) ->
    receive
        {Port, {data, Bytes}} ->
            collect_fresh_vm(Port, [Bytes | Reversed]);
        {Port, {exit_status, 0}} ->
            Output = iolist_to_binary(lists:reverse(Reversed)),
            ?assertNotEqual(nomatch,
                            binary:match(Output, <<"STORE_FRESH_VM_OK">>)),
            ok;
        {Port, {exit_status, Status}} ->
            Output = iolist_to_binary(lists:reverse(Reversed)),
            erlang:error({fresh_store_vm_failed, Status, Output})
    after 30000 ->
        port_close(Port),
        erlang:error(fresh_store_vm_timeout)
    end.

store_source_guarantees(Root, Release, Docset) ->
    ?assertEqual({ok, Docset}, 'ldoc-store':get(Root, Release)),
    TempNames = case file:list_dir(Root) of
                    {ok, Names} -> Names;
                    {error, Reason} -> erlang:error({store_listing, Reason})
                end,
    ?assertEqual([], [Name || Name <- TempNames,
                              lists:prefix(".ldoc-", Name)]).

analysis_s01_s05(Temp, StoreRoot, Inputs, Docset1, Docset2) ->
    Release1 = maps:get(release, Docset1),
    Release2 = maps:get(release, Docset2),
    {ok, Retrieved1} = 'ldoc-store':get(StoreRoot, Release1),
    {ok, Retrieved2} = 'ldoc-store':get(StoreRoot, Release2),
    ?assertEqual(Docset1, Retrieved1),
    ?assertEqual(Docset2, Retrieved2),
    {ok, View1} = 'ldoc-analysis':view(Retrieved1),
    {ok, View2} = 'ldoc-analysis':view(Retrieved2),
    ?assertEqual([languages, release], lists:sort(maps:keys(View1))),
    ?assertEqual([languages, release], lists:sort(maps:keys(View2))),
    ?assertEqual([<<"erlang">>, <<"lfe">>],
                 [maps:get(name, Language) ||
                     Language <- maps:get(languages, View1)]),
    ?assertEqual([<<"ldoc_classic">>, <<"ldoc_modern">>],
                 [maps:get(name, Module) ||
                     Module <- module_views(View1, <<"erlang">>)]),
    ?assertEqual([<<"ldoc-fixture">>, <<"ldoc-legacy">>],
                 [maps:get(name, Module) ||
                     Module <- module_views(View1, <<"lfe">>)]),
    analysis_app_contract(),
    ?assertEqual(View1, element(2, 'ldoc-analysis':view(
                                   Retrieved1#{modules :=
                                       lists:reverse(maps:get(modules,
                                                              Retrieved1))}))),
    ReversedEntries = map_modules(
                        fun(Module) ->
                            Module#{entries := lists:reverse(
                                                   maps:get(entries, Module))}
                        end,
                        Retrieved1),
    ?assertEqual(View1, element(2, 'ldoc-analysis':view(ReversedEntries))),
    Index = consumer_indexes([View1, View2]),
    ?assertEqual(2, maps:size(Index)),
    #{Release1 := Index1, Release2 := Index2} = Index,
    ?assertEqual(Index1, Index2),
    Definitions = maps:get(definitions, Index1),
    ?assertEqual(14, maps:size(Definitions)),
    ?assertEqual(2, maps:get(language_count, Index1)),
    ?assertEqual(4, maps:get(module_count, Index1)),
    LfeOne = {<<"lfe">>, <<"ldoc-fixture">>, <<"function">>,
              <<"sample">>, 1},
    LfeTwo = {<<"lfe">>, <<"ldoc-fixture">>, <<"function">>,
              <<"sample">>, 2},
    ?assert(maps:is_key(LfeOne, Definitions)),
    ?assert(maps:is_key(LfeTwo, Definitions)),
    ?assertNot(maps:is_key({<<"lfe">>, <<"ldoc-fixture">>,
                            <<"function">>,
                            <<"LFE-EXPAND-EXPORTED-MACRO">>, 3},
                           Definitions)),
    LegacyMacro = maps:get({<<"lfe">>, <<"ldoc-legacy">>, <<"macro">>,
                            <<"show">>, unknown}, Definitions),
    ?assertEqual([{[x], [[is_atom, x]]}, {[x], []}],
                 maps:get(patterns, LegacyMacro)),
    ?assertEqual([], maps:get(signatures, LegacyMacro)),
    Classic = maps:get({<<"erlang">>, <<"ldoc_classic">>,
                        <<"function">>, <<"show">>, 1}, Definitions),
    ?assertEqual(#{<<"en">> => [{p, [], [<<"Show the input.">>]}]},
                 maps:get(doc, Classic)),
    ?assertEqual([<<"show(X)">>], maps:get(signatures, Classic)),
    ModernHidden = maps:get({<<"erlang">>, <<"ldoc_modern">>,
                             <<"function">>, <<"hidden">>, 0}, Definitions),
    ?assertEqual(hidden, maps:get(doc, ModernHidden)),
    assert_view_fields(View1),
    analysis_kind_identity(Retrieved1),
    analysis_doc_states(Retrieved1, View1),
    analysis_sources(Temp, Retrieved1, View1),
    analysis_invalid_inputs(Retrieved1),
    PathText = <<"Read /tmp/example.erl before continuing.">>,
    PathDocset = map_entry(
                   fun(Entry) ->
                       Entry#{doc := #{<<"en">> => PathText}}
                   end,
                   Retrieved1, <<"ldoc-fixture">>, <<"function">>,
                   <<"sample">>, 1),
    {ok, PathView} = 'ldoc-analysis':view(PathDocset),
    ?assertEqual(#{<<"en">> => PathText},
                 maps:get(doc, view_definition(
                                PathView, <<"lfe">>, <<"ldoc-fixture">>,
                                <<"function">>, <<"sample">>, 1))),
    {ok, _} = 'ldoc-docset':assemble(maps:get(release, Retrieved1), Inputs),
    ok.

analysis_app_contract() ->
    AppPath = code:where_is_file("ldoc.app"),
    {ok, [{application, ldoc, Properties}]} = file:consult(AppPath),
    Modules = proplists:get_value(modules, Properties),
    ?assert(lists:member('ldoc-analysis', Modules)),
    Applications = proplists:get_value(applications, Properties),
    ?assert(lists:member(lfe, Applications)),
    ?assert(lists:member(crypto, Applications)),
    Exports = 'ldoc-analysis':module_info(exports),
    PublicExports = lists:sort(
                      [Export || Export = {Name, _Arity} <- Exports,
                                 Name =/= '__info__',
                                 Name =/= 'LFE-EXPAND-EXPORTED-MACRO',
                                 Name =/= module_info]),
    ?assertEqual([{view, 1}, {view, 2}], PublicExports),
    ok.

consumer_indexes(Views) ->
    maps:from_list([{maps:get(release, View), consumer_index(View)} ||
                       View <- Views]).

consumer_index(View) ->
    Languages = maps:get(languages, View),
    Definitions = lists:foldl(
                    fun(#{name := Language, modules := Modules}, Acc0) ->
                        lists:foldl(
                          fun(#{name := ModuleName,
                                definitions := Public}, Acc1) ->
                              lists:foldl(
                                fun(Definition, Acc2) ->
                                    Key = {Language, ModuleName,
                                           maps:get(kind, Definition),
                                           maps:get(name, Definition),
                                           maps:get(arity, Definition)},
                                    maps:put(Key, Definition, Acc2)
                                end, Acc1, Public)
                          end, Acc0, Modules)
                    end, #{}, Languages),
    #{language_count => length(Languages),
      module_count => lists:sum([length(maps:get(modules, Language)) ||
                                    Language <- Languages]),
      definitions => Definitions}.

assert_view_fields(View) ->
    LanguageNames = [maps:get(name, Language) ||
                       Language <- maps:get(languages, View)],
    ?assertEqual(lists:sort(LanguageNames), LanguageNames),
    lists:foreach(
      fun(Language) ->
          ?assertEqual([modules, name], lists:sort(maps:keys(Language))),
          ModuleNames = [maps:get(name, Module) ||
                           Module <- maps:get(modules, Language)],
          ?assertEqual(lists:sort(ModuleNames), ModuleNames),
          lists:foreach(
            fun(Module) ->
                ?assertEqual([definitions, doc, format, name],
                             lists:sort(maps:keys(Module))),
                DefinitionKeys = [
                                   {maps:get(kind, Definition),
                                    maps:get(name, Definition),
                                    maps:get(arity, Definition)} ||
                                     Definition <- maps:get(definitions,
                                                            Module)],
                ?assertEqual(lists:sort(DefinitionKeys), DefinitionKeys),
                lists:foreach(
                  fun(Definition) ->
                      Keys = lists:sort(maps:keys(Definition)),
                      ?assert(lists:member(Keys,
                                           [[arity, doc, kind, name,
                                             signatures],
                                            [arity, doc, kind, name,
                                             patterns, signatures]]))
                  end, maps:get(definitions, Module))
            end, maps:get(modules, Language))
      end, maps:get(languages, View)),
    ok.

analysis_doc_states(Docset, View) ->
    NoneModuleDocset = update_module(
                         fun(Module) -> Module#{doc := none} end,
                         Docset, <<"ldoc-fixture">>),
    {ok, NoneModuleView} = 'ldoc-analysis':view(NoneModuleDocset),
    ?assertEqual(none, maps:get(doc, view_module(
                                    NoneModuleView, <<"lfe">>,
                                    <<"ldoc-fixture">>))),
    EmptyModuleDocset = update_module(
                          fun(Module) -> Module#{doc := #{}} end,
                          Docset, <<"ldoc-fixture">>),
    {ok, EmptyModuleView} = 'ldoc-analysis':view(EmptyModuleDocset),
    ?assertEqual(#{}, maps:get(doc, view_module(
                                     EmptyModuleView, <<"lfe">>,
                                     <<"ldoc-fixture">>))),
    ?assertEqual(#{<<"en">> => <<"Fixture module.">>},
                 maps:get(doc, view_module(View, <<"lfe">>,
                                          <<"ldoc-fixture">>))),
    EmptyDocset = map_entry(fun(Entry) -> Entry#{doc := #{}} end,
                            Docset, <<"ldoc-fixture">>,
                            <<"function">>, <<"bare">>, 0),
    {ok, EmptyView} = 'ldoc-analysis':view(EmptyDocset),
    ?assertEqual(#{}, maps:get(doc, view_definition(
                                     EmptyView, <<"lfe">>,
                                     <<"ldoc-fixture">>, <<"function">>,
                                     <<"bare">>, 0))),
    SecretText = <<"secret prose">>,
    HiddenModuleDocset = update_module(
                           fun(Module) -> Module#{doc := hidden} end,
                           map_entry(
                             fun(Entry) ->
                                 Entry#{doc := #{<<"en">> => SecretText}}
                             end, Docset, <<"ldoc-fixture">>,
                             <<"function">>, <<"sample">>, 1),
                           <<"ldoc-fixture">>),
    {ok, HiddenView} = 'ldoc-analysis':view(HiddenModuleDocset),
    HiddenModule = view_module(HiddenView, <<"lfe">>,
                               <<"ldoc-fixture">>),
    ?assertEqual(hidden, maps:get(doc, HiddenModule)),
    ?assertEqual([], maps:get(definitions, HiddenModule)),
    ?assertNot(maps:is_key(source, HiddenModule)),
    HiddenStored = module_named(maps:get(modules, HiddenModuleDocset),
                                <<"ldoc-fixture">>),
    ?assertEqual(#{<<"en">> => SecretText},
                 entry_doc(maps:get(entries, HiddenStored), <<"function">>,
                           <<"sample">>, 1)),
    ?assertEqual(#{<<"en">> => <<"Get a value.">>},
                 maps:get(doc, view_definition(
                                View, <<"erlang">>, <<"ldoc_modern">>,
                                <<"callback">>, <<"get">>, 0))),
    ok.

analysis_kind_identity(Docset) ->
    Module = module_named(maps:get(modules, Docset), <<"ldoc_modern">>),
    Type = entry(maps:get(entries, Module), <<"type">>, <<"value">>, 0),
    Function = Type#{kind := <<"function">>, doc := none, signatures := []},
    Variant = update_module(
                fun(Current) ->
                    Current#{entries := [Function | maps:get(entries, Current)]}
                end, Docset, <<"ldoc_modern">>),
    {ok, VariantView} = 'ldoc-analysis':view(Variant),
    VariantIndex = consumer_index(VariantView),
    Definitions = maps:get(definitions, VariantIndex),
    FunctionKey = {<<"erlang">>, <<"ldoc_modern">>, <<"function">>,
                   <<"value">>, 0},
    TypeKey = {<<"erlang">>, <<"ldoc_modern">>, <<"type">>,
               <<"value">>, 0},
    ?assert(maps:is_key(FunctionKey, Definitions)),
    ?assert(maps:is_key(TypeKey, Definitions)),
    ?assertNotEqual(maps:get(FunctionKey, Definitions),
                    maps:get(TypeKey, Definitions)),
    ok.

analysis_sources(Temp, Docset, DefaultView) ->
    Root = filename:absname(Temp),
    {ok, Sourced} = 'ldoc-analysis':view(Docset, #{source_root => Root}),
    ?assertEqual(Sourced,
                 element(2, 'ldoc-analysis':view(
                              Docset, #{source_root => list_to_binary(Root)}))),
    ?assertEqual(<<"ldoc_classic.erl">>,
                 maps:get(path, maps:get(source,
                     view_module(Sourced, <<"erlang">>,
                                 <<"ldoc_classic">>)))),
    ?assert(is_binary(maps:get(path, maps:get(source,
                     view_module(Sourced, <<"erlang">>,
                                 <<"ldoc_classic">>))))),
    Modern = view_module(Sourced, <<"erlang">>, <<"ldoc_modern">>),
    ?assertEqual(<<"ldoc_modern.erl">>,
                 maps:get(path, maps:get(source, Modern))),
    ModernShow = view_definition(Sourced, <<"erlang">>, <<"ldoc_modern">>,
                                 <<"function">>, <<"show">>, 1),
    ?assertEqual(<<"ldoc_modern.erl">>,
                 maps:get(path, maps:get(source, ModernShow))),
    ?assert(maps:get(line, maps:get(source, ModernShow)) > 0),
    Classic = view_module(Sourced, <<"erlang">>, <<"ldoc_classic">>),
    ?assert(maps:get(line, maps:get(source, Classic)) > 0),
    ClassicShow = view_definition(Sourced, <<"erlang">>,
                                  <<"ldoc_classic">>, <<"function">>,
                                  <<"show">>, 1),
    ?assert(maps:get(line, maps:get(source, ClassicShow)) > 0),
    lists:foreach(
      fun(Module) ->
          ?assertNot(maps:is_key(source, Module)),
          lists:foreach(fun(Definition) ->
                            ?assertNot(maps:is_key(source, Definition))
                        end, maps:get(definitions, Module))
      end, module_views(Sourced, <<"lfe">>)),
    assert_source_fields(Sourced),
    ?assertEqual(false, any_source_field(DefaultView)),
    Sibling = Root ++ "-other/source.erl",
    OutsideDocset = update_module(
                      fun(Module) ->
                          Module#{metadata := #{source_path => Sibling}}
                      end, Docset, <<"ldoc-fixture">>),
    {ok, OutsideView} = 'ldoc-analysis':view(
                          OutsideDocset, #{source_root => Root}),
    ?assertNot(maps:is_key(source,
                           view_module(OutsideView, <<"lfe">>,
                                       <<"ldoc-fixture">>))),
    Traversal = filename:join([Root, "..", "escape", "source.erl"]),
    TraversalDocset = update_module(
                        fun(Module) ->
                            Module#{metadata := #{source_path => Traversal}}
                        end, Docset, <<"ldoc-fixture">>),
    {ok, TraversalView} = 'ldoc-analysis':view(
                            TraversalDocset, #{source_root => Root}),
    ?assertNot(maps:is_key(source,
                           view_module(TraversalView, <<"lfe">>,
                                       <<"ldoc-fixture">>))),
    RelativeEntry = map_entry(
                      fun(Entry) ->
                          Entry#{annotation :=
                                     erl_anno:set_file("dir/show.erl",
                                                       erl_anno:new(23))}
                      end,
                      update_module(
                        fun(Module) ->
                            Module#{metadata :=
                                        #{source_path => filename:join(
                                                             [Root, "src",
                                                              "module.erl"])}}
                        end, Docset, <<"ldoc-fixture">>),
                      <<"ldoc-fixture">>, <<"function">>, <<"sample">>, 1),
    {ok, RelativeView} = 'ldoc-analysis':view(
                           RelativeEntry, #{source_root => Root}),
    RelativeDefinition = view_definition(RelativeView, <<"lfe">>,
                                         <<"ldoc-fixture">>,
                                         <<"function">>, <<"sample">>, 1),
    ?assertNot(maps:is_key(source, RelativeDefinition)),
    BasenameEntry = map_entry(
                      fun(Entry) ->
                          Entry#{annotation :=
                                     erl_anno:set_file("module.erl",
                                                       erl_anno:new(24))}
                      end,
                      update_module(
                        fun(Module) ->
                            Module#{metadata :=
                                        #{source_path => filename:join(
                                                             [Root, "src",
                                                              "module.erl"])}}
                        end, Docset, <<"ldoc-fixture">>),
                      <<"ldoc-fixture">>, <<"function">>, <<"sample">>, 1),
    {ok, BasenameView} = 'ldoc-analysis':view(
                           BasenameEntry, #{source_root => Root}),
    BasenameDefinition = view_definition(BasenameView, <<"lfe">>,
                                          <<"ldoc-fixture">>,
                                          <<"function">>, <<"sample">>, 1),
    ?assertEqual(<<"src/module.erl">>,
                 maps:get(path, maps:get(source, BasenameDefinition))),
    ?assertEqual(24, maps:get(line, maps:get(source, BasenameDefinition))),
    ExplicitPath = filename:join([Root, "src", "explicit.erl"]),
    Explicit = map_entry(
                 fun(Entry) ->
                     Metadata = maps:get(metadata, Entry, #{}),
                     Entry#{metadata := Metadata#{source_anno =>
                         erl_anno:set_file(ExplicitPath,
                                           erl_anno:new(71))}}
                 end,
                 update_module(
                   fun(Module) ->
                       Module#{metadata := #{source_path => filename:join(
                                                            [Root, "src",
                                                             "module.erl"])}}
                   end, Docset, <<"ldoc-fixture">>),
                 <<"ldoc-fixture">>, <<"function">>, <<"sample">>, 1),
    {ok, ExplicitView} = 'ldoc-analysis':view(
                           Explicit, #{source_root => Root}),
    ExplicitDefinition = view_definition(ExplicitView, <<"lfe">>,
                                         <<"ldoc-fixture">>,
                                         <<"function">>, <<"sample">>, 1),
    ?assertEqual(<<"src/explicit.erl">>,
                 maps:get(path, maps:get(source, ExplicitDefinition))),
    ?assert(is_binary(maps:get(path, maps:get(source, ExplicitDefinition)))),
    ?assertEqual(71, maps:get(line, maps:get(source, ExplicitDefinition))),
    RootBinary = list_to_binary(Root),
    NullFilename = <<RootBinary/binary, "/src/bad", 0, ".erl">>,
    NullPathDocset = update_module(
                       fun(Module) ->
                           Module#{metadata := #{source_path => NullFilename},
                                   source := malformed}
                       end, Docset, <<"ldoc-fixture">>),
    {ok, NullPathView} = 'ldoc-analysis':view(
                           NullPathDocset, #{source_root => Root}),
    ?assertNot(maps:is_key(source,
                           view_module(NullPathView, <<"lfe">>,
                                       <<"ldoc-fixture">>))),
    ValidFallback = update_module(
                      fun(Module) ->
                          Module#{metadata :=
                                      #{source_path => filename:join(
                                                           [Root, "src",
                                                            "fallback.erl"])},
                                  source := malformed}
                      end, Docset, <<"ldoc-fixture">>),
    {ok, FallbackView} = 'ldoc-analysis':view(
                           ValidFallback, #{source_root => Root}),
    ?assertEqual(<<"src/fallback.erl">>,
                 maps:get(path, maps:get(source,
                     view_module(FallbackView, <<"lfe">>,
                                 <<"ldoc-fixture">>)))),
    AnnotationFallback = update_module(
                           fun(Module) ->
                               Module#{metadata := malformed,
                                       source := malformed,
                                       annotation := erl_anno:set_file(
                                         filename:join([Root, "src",
                                                        "annotation.erl"]),
                                         erl_anno:new(5))}
                           end, Docset, <<"ldoc-fixture">>),
    {ok, AnnotationFallbackView} = 'ldoc-analysis':view(
                                     AnnotationFallback,
                                     #{source_root => Root}),
    ?assertEqual(<<"src/annotation.erl">>,
                 maps:get(path, maps:get(source,
                     view_module(AnnotationFallbackView, <<"lfe">>,
                                 <<"ldoc-fixture">>)))),
    NoProvenance = update_module(
                     fun(Module) ->
                         Module#{metadata := malformed,
                                 source := malformed,
                                 annotation := malformed}
                     end, Docset, <<"ldoc-fixture">>),
    {ok, NoProvenanceView} = 'ldoc-analysis':view(
                               NoProvenance, #{source_root => Root}),
    ?assertNot(maps:is_key(source,
                           view_module(NoProvenanceView, <<"lfe">>,
                                       <<"ldoc-fixture">>))),
    BadEntryMetadata = map_entry(
                         fun(Entry) ->
                             Entry#{metadata := malformed,
                                    annotation := erl_anno:set_file(
                                      filename:join([Root, "src",
                                                     "entry-fallback.erl"]),
                                      erl_anno:new(9))}
                         end, Docset, <<"ldoc-fixture">>, <<"function">>,
                         <<"sample">>, 1),
    {ok, BadEntryMetadataView} = 'ldoc-analysis':view(
                                   BadEntryMetadata,
                                   #{source_root => Root}),
    ?assertEqual(<<"src/entry-fallback.erl">>,
                 maps:get(path, maps:get(source,
                     view_definition(BadEntryMetadataView, <<"lfe">>,
                                     <<"ldoc-fixture">>, <<"function">>,
                                     <<"sample">>, 1)))),
    ok.

analysis_invalid_inputs(Docset) ->
    ?assertEqual({error, invalid_options},
                 'ldoc-analysis':view(#{}, #{bad => true})),
    ?assertEqual({error, invalid_options},
                 'ldoc-analysis':view(Docset, #{source_root => "relative"})),
    ?assertEqual({error, invalid_options},
                 'ldoc-analysis':view(Docset, #{source_root => <<255>>})),
    ?assertEqual({error, invalid_options},
                 'ldoc-analysis':view(Docset,
                                      #{source_root => <<"/tmp/ldoc", 0,
                                                        "/root">>})),
    ?assertEqual({error, invalid_options},
                 'ldoc-analysis':view(Docset,
                                      #{source_root => "/tmp/ldoc" ++ [0] ++
                                                       "/root"})),
    ?assertEqual({error, invalid_docset},
                 'ldoc-analysis':view(#{release => #{}, modules => []})),
    ?assertEqual({error, invalid_docset},
                 'ldoc-analysis':view(Docset#{modules := []})),
    [FirstModule | _] = maps:get(modules, Docset),
    ?assertEqual({error, invalid_docset},
                 'ldoc-analysis':view(Docset#{modules :=
                                                  [FirstModule | improper]})),
    ?assertEqual({error, invalid_docset},
                 'ldoc-analysis':view(Docset#{modules :=
                                                  [FirstModule, FirstModule]})),
    [FirstEntry | _] = maps:get(entries, FirstModule),
    BadEntries = FirstModule#{entries := [FirstEntry | improper]},
    ?assertEqual({error, invalid_docset},
                 'ldoc-analysis':view(replace_first_module(
                                         Docset, BadEntries))),
    DuplicateEntry = FirstModule#{entries := [FirstEntry, FirstEntry]},
    ?assertEqual({error, invalid_docset},
                 'ldoc-analysis':view(replace_first_module(
                                         Docset, DuplicateEntry))),
    BadSignatures = FirstEntry#{signatures := [<<"ok">> | improper]},
    BadModule = FirstModule#{entries := [BadSignatures |
                                          tl(maps:get(entries, FirstModule))]},
    ?assertEqual({error, invalid_docset},
                 'ldoc-analysis':view(replace_first_module(Docset, BadModule))),
    ok.

map_modules(Fun, Docset) ->
    Docset#{modules := [Fun(Module) || Module <- maps:get(modules, Docset)]}.

map_entry(Fun, Docset, ModuleName, Kind, Name, Arity) ->
    update_module(
      fun(Module) ->
          Entries = [case {maps:get(kind, Entry), maps:get(name, Entry),
                          maps:get(arity, Entry)} of
                         {Kind, Name, Arity} -> Fun(Entry);
                         _ -> Entry
                     end || Entry <- maps:get(entries, Module)],
          Module#{entries := Entries}
      end, Docset, ModuleName).

update_module(Fun, Docset, ModuleName) ->
    map_modules(fun(Module) ->
                    case maps:get(name, Module) of
                        ModuleName -> Fun(Module);
                        _ -> Module
                    end
                end, Docset).

replace_first_module(Docset, Replacement) ->
    [_ | Tail] = maps:get(modules, Docset),
    Docset#{modules := [Replacement | Tail]}.

module_views(View, Language) ->
    [Modules] = [maps:get(modules, Group) || Group <- maps:get(languages, View),
                 maps:get(name, Group) =:= Language],
    Modules.

view_module(View, Language, Name) ->
    [Module] = [M || M <- module_views(View, Language),
                     maps:get(name, M) =:= Name],
    Module.

view_definition(View, Language, ModuleName, Kind, Name, Arity) ->
    Module = view_module(View, Language, ModuleName),
    [Definition] = [D || D <- maps:get(definitions, Module),
                         maps:get(kind, D) =:= Kind,
                         maps:get(name, D) =:= Name,
                         maps:get(arity, D) =:= Arity],
    Definition.

any_source_field(View) ->
    lists:any(fun(Group) ->
                  lists:any(fun(Module) ->
                                maps:is_key(source, Module) orelse
                                lists:any(fun(Definition) ->
                                              maps:is_key(source, Definition)
                                          end,
                                          maps:get(definitions, Module))
                            end, maps:get(modules, Group))
              end, maps:get(languages, View)).

assert_source_fields(View) ->
    lists:foreach(
      fun(Group) ->
          lists:foreach(
            fun(Module) ->
                assert_source_map(maps:get(source, Module, none)),
                lists:foreach(fun(Definition) ->
                                  assert_source_map(
                                    maps:get(source, Definition, none))
                              end, maps:get(definitions, Module))
            end, maps:get(modules, Group))
      end, maps:get(languages, View)),
    ok.

assert_source_map(none) ->
    ok;
assert_source_map(Source) ->
    Keys = lists:sort(maps:keys(Source)),
    ?assert(lists:member(Keys, [[path], [line, path]])),
    Path = maps:get(path, Source),
    ?assert(is_binary(Path)),
    ?assertEqual(relative, filename:pathtype(Path)),
    ?assertNotEqual(<<>>, Path),
    ok.

module_named(Modules, Name) ->
    [Module] = [M || M <- Modules, maps:get(name, M) =:= Name],
    Module.

fixture_loads() ->
    [{Module, code:is_loaded(Module)} || Module <-
         ['ldoc-fixture', ldoc_modern, ldoc_classic, 'ldoc-legacy']].

assemble_without_loading(Release, Inputs) ->
    CodePath = code:get_path(),
    FixtureLoads = fixture_loads(),
    Result = 'ldoc-docset':assemble(Release, Inputs),
    ?assertEqual(CodePath, code:get_path()),
    ?assertEqual(FixtureLoads, fixture_loads()),
    Result.

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
