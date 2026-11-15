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
    store_producer_oracles(Root, Release1, Docset1, ErlPath),
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

store_producer_oracles(Root, Release, Docset, ErlPath) ->
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
    {ok, ErlBeam} = file:read_file(ErlPath),
    ProducerDocs = docs_term(ErlBeam),
    ?assertEqual(element(2, ProducerDocs), maps:get(annotation, Modern)),
    ?assertEqual(element(6, ProducerDocs), maps:get(metadata, Modern)),
    ModernShow = entry(ModernEntries, <<"function">>, <<"show">>, 1),
    RawShow = [Raw || Raw <- element(7, ProducerDocs),
                      element(1, Raw) =:= {function, show, 1}],
    [ProducerShow] = RawShow,
    ?assertEqual(element(2, ProducerShow),
                 maps:get(annotation, ModernShow)),
    ?assertEqual(element(5, ProducerShow),
                 maps:get(metadata, ModernShow)),
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
        try port_close(Port)
        catch error:badarg -> ok
        end
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
    html_s01_s06(Temp, StoreRoot, Docset1, Docset2,
                 Retrieved1, Retrieved2, View1, View2),
    site_s01_s06(Temp, StoreRoot, Retrieved1, Retrieved2, View1, View2),
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
    {ok, PostViewRetrieved1} = 'ldoc-store':get(StoreRoot, Release1),
    {ok, PostViewRetrieved2} = 'ldoc-store':get(StoreRoot, Release2),
    ?assertEqual(Docset1, PostViewRetrieved1),
    ?assertEqual(Docset2, PostViewRetrieved2),
    {ok, _} = 'ldoc-docset':assemble(maps:get(release, Retrieved1), Inputs),
    ok.

html_s01_s06(Temp, StoreRoot, Docset1, Docset2,
             Retrieved1, Retrieved2, View1, View2) ->
    Release1 = maps:get(release, Docset1),
    Release2 = maps:get(release, Docset2),
    BeforeTerm1 = 'ldoc-store':get(StoreRoot, Release1),
    BeforeTerm2 = 'ldoc-store':get(StoreRoot, Release2),
    BeforeBytes1 = file:read_file(store_path(StoreRoot, Release1)),
    BeforeBytes2 = file:read_file(store_path(StoreRoot, Release2)),
    {ok, View1} = 'ldoc-analysis':view(Retrieved1),
    {ok, View2} = 'ldoc-analysis':view(Retrieved2),
    {ok, Bundle} = 'ldoc-html':render(View1),
    DefaultIndex = proplists:get_value(<<"index.html">>, Bundle),
    ?assert(binary:match(DefaultIndex, <<">Filter API navigation</label>">>) =/= nomatch),
    {ok, EmptyPagesBundle} = 'ldoc-html':render(View1, #{pages => []}),
    EmptyPagesIndex = proplists:get_value(<<"index.html">>, EmptyPagesBundle),
    ?assert(binary:match(EmptyPagesIndex,
                         <<">Filter documentation navigation</label>">>) =/= nomatch),
    PageSpec = #{path => <<"docs/guide.md">>, title => <<"Guide"/utf8>>,
                 body => <<"# Start here\n\n## Same\n\n## Same\n\n## Same-1\n\n[second](#same-1) **[overview](../README.md#home)**.">>},
    ?assert('ldoc-html':'valid-options?'(#{pages => [PageSpec], overview => <<"# Home">>})),
    {ok, PageBundle} = 'ldoc-html':render(
                         View1, #{pages => [PageSpec], overview => <<"# Home">>}),
    PageRoute = 'ldoc-pages':route(<<"docs/guide.md">>),
    PageHtml = proplists:get_value(PageRoute, PageBundle),
    ?assert(is_binary(PageHtml)),
    ?assert(binary:match(PageHtml, <<"Start here">>) =/= nomatch),
    ?assert(binary:match(PageHtml, <<"id=\"h-start-here\"">>) =/= nomatch),
    ?assert(binary:match(PageHtml, <<"id=\"h-same\"">>) =/= nomatch),
    ?assert(binary:match(PageHtml, <<"id=\"h-same-1\"">>) =/= nomatch),
    ?assert(binary:match(PageHtml, <<"id=\"h-same-1-1\"">>) =/= nomatch),
    ?assert(binary:match(PageHtml, <<"href=\"", PageRoute/binary, "#h-same-1\">second</a>">>) =/= nomatch),
    ?assert(binary:match(PageHtml, <<"href=\"index.html#h-home\"">>) =/= nomatch),
    ?assert(binary:match(PageHtml, <<">Guide</a>">>) =/= nomatch),
    ?assertEqual(1, length(binary:matches(PageHtml, <<"aria-current=\"page\"">>))),
    ?assert(binary:match(PageHtml, <<"href=\"", PageRoute/binary, "\" aria-current=\"page\"">>) =/= nomatch),
    PageIndex = proplists:get_value(<<"index.html">>, PageBundle),
    ?assertEqual(1, length(binary:matches(PageIndex, <<"aria-current=\"page\"">>))),
    PageModuleName = hd([Name || {Name, _} <- PageBundle,
                                  binary:match(Name, <<"m-">>) =:= {0, 2}]),
    PageModuleHtml = proplists:get_value(PageModuleName, PageBundle),
    ?assertEqual(1, length(binary:matches(PageModuleHtml, <<"aria-current=\"page\"">>))),
    [FirstLanguage | OtherLanguages] = maps:get(languages, View1),
    [FirstModule | OtherModules] = maps:get(modules, FirstLanguage),
    [FirstDefinition | OtherDefinitions] = maps:get(definitions, FirstModule),
    CrossDefinition = FirstDefinition#{doc := #{<<"en">> => <<"## Definition heading">>}},
    CrossModule = FirstModule#{format := <<"text/markdown">>,
                               doc := #{<<"en">> =>
                                 <<"## Definition heading\n\n[Jump](#definition-heading-1)">>},
                               definitions := [CrossDefinition | OtherDefinitions]},
    CrossLanguage = FirstLanguage#{modules := [CrossModule | OtherModules]},
    CrossView = View1#{languages := [CrossLanguage | OtherLanguages]},
    {ok, CrossBundle} = 'ldoc-html':render(CrossView, #{pages => []}),
    CrossModuleName = module_html_name(maps:get(name, FirstLanguage),
                                       maps:get(name, FirstModule)),
    CrossModuleHtml = proplists:get_value(CrossModuleName, CrossBundle),
    ?assert(binary:match(CrossModuleHtml, <<"href=\"#h-definition-heading-1\">Jump</a>">>) =/= nomatch),
    ?assert(binary:match(CrossModuleHtml, <<"id=\"h-definition-heading\"">>) =/= nomatch),
    ?assert(binary:match(CrossModuleHtml, <<"id=\"h-definition-heading-1\"">>) =/= nomatch),
    ?assertEqual({error, invalid_options},
                 'ldoc-html':render(View1, #{overview_path => <<"README.md">>})),
    ?assertEqual({error, invalid_options},
                 'ldoc-html':render(View1, #{pages => [PageSpec, PageSpec]})),
    ?assertEqual({error, invalid_options},
                 'ldoc-html':render(View1, #{pages => [PageSpec#{path := <<"../bad.md">>}]})),
    RootPage = #{path => <<"guide.md">>,
                 body => <<"# Root\n\n[Overview](docs/overview.md#home)\n\n[go](guide.md) and `[literal](guide.md)`.\n\n[empty](guide.md#) [#](#)">>},
    {ok, RootBundle} = 'ldoc-html':render(
      View1, #{pages => [RootPage], overview_path => <<"docs/overview.md">>,
               overview => <<"# Home">>}),
    RootRoute = 'ldoc-pages':route(<<"guide.md">>),
    RootHtml = proplists:get_value(RootRoute, RootBundle),
    ?assert(binary:match(RootHtml,
                         <<"href=\"index.html#h-home\">Overview</a>">>) =/= nomatch),
    ?assert(binary:match(RootHtml,
                         <<"href=\"", RootRoute/binary, "\">go</a>">>) =/= nomatch),
    ?assert(binary:match(RootHtml,
                         <<"href=\"", RootRoute/binary, "\">empty</a>">>) =/= nomatch),
    ?assert(binary:match(RootHtml, <<"<code>[literal](guide.md)</code>">>) =/= nomatch),
    ?assertEqual(nomatch, binary:match(RootHtml, <<"<code><a href=">>)),
    ?assert(binary:match(RootHtml, <<"href=\"#main\">#</a>">>) =/= nomatch),
    ?assertEqual(1, length(binary:matches(
                      proplists:get_value(<<"index.html">>, RootBundle),
                      <<"href=\"index.html\" aria-current=\"page\"">>))),
    ?assert(binary:match(PageModuleHtml,
                         <<"href=\"", PageModuleName/binary, "\" aria-current=\"page\"">>) =/= nomatch),
    SlugPage = #{path => <<"docs/slugs.md">>,
                 body => <<"# [**Guide**](https://example.test)\n\n## Guide\n\n## Guide-1\n\n## Café\n\n## Café\n\n## !!!\n\n## A B"/utf8>>},
    SlugResult = 'ldoc-html':render(View1, #{pages => [SlugPage]}),
    {ok, SlugBundle} = SlugResult,
    SlugRoute = 'ldoc-pages':route(<<"docs/slugs.md">>),
    SlugHtml = proplists:get_value(SlugRoute, SlugBundle),
    ?assert(binary:match(SlugHtml, <<"id=\"h-guide\"">>) =/= nomatch),
    ?assert(binary:match(SlugHtml, <<"id=\"h-guide-1\"">>) =/= nomatch),
    ?assert(binary:match(SlugHtml, <<"id=\"h-guide-1-1\"">>) =/= nomatch),
    ?assert(binary:match(SlugHtml, <<"id=\"h-caf\xC3\xA9\"">>) =/= nomatch),
    ?assert(binary:match(SlugHtml, <<"id=\"h-caf\xC3\xA9-1\"">>) =/= nomatch),
    ?assert(binary:match(SlugHtml, <<"id=\"h-section\"">>) =/= nomatch),
    ?assert(binary:match(SlugHtml, <<"id=\"h-a-b\"">>) =/= nomatch),
    ?assertEqual(7, length(binary:matches(SlugHtml, <<" id=\"h-">>))),
    ?assert(binary:match(proplists:get_value(<<"index.html">>, SlugBundle),
                         <<">Guide</a>">>) =/= nomatch),
    ForwardPages = [#{path => <<"docs/a.md">>,
                      body => <<"[next](b%2Emd#%74arget) [space](a%20b.md#space)">>},
                    #{path => <<"docs/b.md">>, body => <<"## Target">>},
                    #{path => <<"docs/a b.md">>, body => <<"## Space">>}],
    {ok, ForwardBundle} = 'ldoc-html':render(View1, #{pages => ForwardPages}),
    ARoute = 'ldoc-pages':route(<<"docs/a.md">>),
    BRoute = 'ldoc-pages':route(<<"docs/b.md">>),
    SpaceRoute = 'ldoc-pages':route(<<"docs/a b.md">>),
    AHtml = proplists:get_value(ARoute, ForwardBundle),
    ?assert(binary:match(AHtml, <<"href=\"", BRoute/binary, "#h-target\">next</a>">>) =/= nomatch),
    ?assert(binary:match(AHtml, <<"href=\"", SpaceRoute/binary, "#h-space\">space</a>">>) =/= nomatch),
    NfdOverview = <<"docs/cafe", 204, 129, ".md">>,
    {ok, NfdOverviewBundle} = 'ldoc-html':render(View1,
      #{overview_path => NfdOverview, overview => <<"# Home">>,
        pages => [#{path => <<"a.md">>, body => <<"[Overview](docs/caf%C3%A9.md#home)">>}]}),
    ?assert(binary:match(proplists:get_value('ldoc-pages':route(<<"a.md">>),
                            NfdOverviewBundle),
                         <<"href=\"index.html#h-home\">Overview</a>">>) =/= nomatch),
    ProcessKeys = ['$ldoc-markup-context', '$ldoc-heading-ids', ldoc_test_sentinel],
    ProcessValues = [preserved_context, preserved_headings, preserved_sentinel],
    lists:foreach(fun({Key, Value}) -> put(Key, Value) end,
                  lists:zip(ProcessKeys, ProcessValues)),
    try
        ?assertMatch({ok, _}, 'ldoc-markup':render(
                                <<"text/markdown">>, <<"# Pure">>,
                                #{headings => [<<"h-pure">>], links => #{}})),
        ?assertEqual({error, invalid_documentation}, 'ldoc-markup':render(
          <<"text/markdown">>, <<"# Heading">>,
          #{headings => [<<"h-heading">>], links => #{}, heading_offset => bad})),
        ?assertEqual({error, invalid_documentation}, 'ldoc-markup':render(
          <<"text/markdown">>, <<"# Test">>,
          #{headings => [], links => #{}})),
        ?assertEqual({error, invalid_documentation}, 'ldoc-markup':render(
          <<"text/markdown">>, <<"# Test">>,
          #{headings => [<<"h-", 255>>], links => #{}})),
        ?assertEqual({error, invalid_documentation}, 'ldoc-markup':render(
          <<"text/markdown">>, <<"# Test">>,
          #{headings => [<<"h-test">> | bad], links => #{}})),
        ?assertEqual({error, invalid_documentation}, 'ldoc-markup':render(
          <<"text/markdown">>, <<"[unsafe](x)">>,
          #{headings => [], links => #{<<"x">> => <<"javascript:alert(1)">>}})),
        ?assertMatch({error, {documentation_link, _}},
                     'ldoc-html':render(View1, #{pages => [
                       #{path => <<"docs/error.md">>, body => <<"[bad](missing.md)">>}]})),
        ?assertEqual(ProcessValues, [get(Key) || Key <- ProcessKeys])
    after
        lists:foreach(fun(Key) -> erase(Key) end, ProcessKeys)
    end,
    FallbackPage = #{path => <<"docs/fallback.md">>,
                     body => <<"[license](LICENSE?raw=1) [unsafe](https://example.test/a b) [upper](HTTPS://example.test/a b)">>},
    {ok, FallbackBundle} = 'ldoc-html':render(View1, #{pages => [FallbackPage]}),
    FallbackHtml = proplists:get_value('ldoc-pages':route(<<"docs/fallback.md">>),
                                       FallbackBundle),
    ?assert(binary:match(FallbackHtml, <<"[license](LICENSE?raw=1)">>) =/= nomatch),
    ?assert(binary:match(FallbackHtml, <<"[unsafe](https://example.test/a b)">>) =/= nomatch),
    ?assert(binary:match(FallbackHtml, <<"[upper](HTTPS://example.test/a b)">>) =/= nomatch),
    ?assertEqual({error, {documentation_link,
                          #{document => <<"docs/bad.md">>,
                            href => <<"missing.md">>,
                            reason => {unknown_page, <<"docs/missing.md">>}}}},
                 'ldoc-html':render(View1,
                   #{pages => [#{path => <<"docs/bad.md">>,
                                 body => <<"[missing](missing.md)">>}]})),
    ?assertEqual({error, {documentation_link,
                          #{document => <<"docs/bad.md">>, href => <<"#absent">>,
                            reason => {unknown_fragment, <<"docs/bad.md">>, <<"absent">>}}}},
                 'ldoc-html':render(View1,
                   #{pages => [#{path => <<"docs/bad.md">>, body => <<"[here](#absent)">>}]})),
    ?assertEqual({error, {documentation_link,
                          #{document => <<"docs/bad.md">>, href => <<"guide.md?raw=1">>,
                            reason => {invalid_local_link, query_not_supported}}}},
                 'ldoc-html':render(View1,
                   #{pages => [#{path => <<"docs/bad.md">>,
                                 body => <<"[query](guide.md?raw=1)">>}]})),
    ?assertEqual({error, {documentation_link,
                          #{document => <<"docs/bad.md">>, href => <<"guide%2Emd">>,
                            reason => {unknown_page, <<"docs/guide.md">>}}}},
                 'ldoc-html':render(View1,
                   #{pages => [#{path => <<"docs/bad.md">>,
                                 body => <<"[encoded](guide%2Emd)">>}]})),
    {ok, OnceBundle} = 'ldoc-html':render(View1,
      #{pages => [#{path => <<"docs/bad.md">>, body => <<"[once](guide%252Emd)">>}]}),
    ?assert(binary:match(proplists:get_value('ldoc-pages':route(<<"docs/bad.md">>),
                            OnceBundle),
                         <<"[once](guide%252Emd)">>) =/= nomatch),
    ?assertEqual({error, {documentation_link,
                          #{document => <<"docs/bad.md">>, href => <<"%FF.md">>,
                            reason => {invalid_local_link, invalid_utf8}}}},
                 'ldoc-html':render(View1,
                   #{pages => [#{path => <<"docs/bad.md">>, body => <<"[bad](%FF.md)">>}]})),
    ?assertEqual({error, {documentation_link,
                          #{document => <<"docs/bad.md">>, href => <<"%2E%2E%2F%2E%2E%2Fsecret.md">>,
                            reason => {invalid_local_link, root_escape}}}},
                 'ldoc-html':render(View1,
                   #{pages => [#{path => <<"docs/bad.md">>,
                                 body => <<"[escape](%2E%2E%2F%2E%2E%2Fsecret.md)">>}]})),
    ComposedPath = <<"docs/caf\xC3\xA9.md">>,
    DecomposedPath = <<"docs/cafe\xCC\x81.md">>,
    ?assertEqual({error, invalid_options},
                 'ldoc-html':render(View1, #{pages => [
                   #{path => ComposedPath, body => <<"ok">>},
                   #{path => DecomposedPath, body => <<"duplicate">>}]})),
    ?assertEqual({error, invalid_options},
                 'ldoc-html':render(View1, #{pages => [
                   #{path => <<"docs/invalid.md">>, body => <<"#", 255>>}]})),
    {ok, ReversedView1} = 'ldoc-analysis':view(
                            Retrieved1#{modules :=
                                lists:reverse(maps:get(modules, Retrieved1))}),
    ?assertEqual(Bundle, element(2, 'ldoc-html':render(ReversedView1))),
    Files = [Name || {Name, _Bytes} <- Bundle],
    ?assertEqual(lists:sort(Files), Files),
    ?assertEqual(7, length(Bundle)),
    ?assert(lists:member(<<"index.html">>, Files)),
    ?assert(lists:member(<<"ldoc.css">>, Files)),
    ?assert(lists:member(<<"ldoc.js">>, Files)),
    ModuleFiles = [Name || Name <- Files,
                           binary:match(Name, <<"m-">>) =:= {0, 2}],
    ?assertEqual([<<"index.html">>, <<"ldoc.css">>, <<"ldoc.js">>] ++
                 lists:sort(ModuleFiles), Files),
    ?assertEqual(4, length(ModuleFiles)),
    lists:foreach(
      fun(Name) ->
          Page = proplists:get_value(Name, Bundle),
          ?assert(binary:match(Page,
              <<"<span class=\"library\">local/beam-fixtures</span><span class=\"version\">1.0</span><span class=\"brand-mark\">ldoc</span>">>) =/= nomatch)
      end, [<<"index.html">> | ModuleFiles]),
    ?assertEqual(14, lists:sum([
        length(maps:get(definitions, Module)) || Language <- maps:get(languages, View1),
        Module <- maps:get(modules, Language)])),
    ActualDefinitionIds = lists:sort(lists:append(
        [html_section_ids(proplists:get_value(Name, Bundle)) || Name <- ModuleFiles])),
    ?assertEqual(14, length(ActualDefinitionIds)),
    ?assertEqual(lists:sort(html_expected_definition_ids(View1)), ActualDefinitionIds),
    ReversedPublicView = reverse_html_view(View1),
    ?assertEqual(Bundle, element(2, 'ldoc-html':render(ReversedPublicView))),
    Index = proplists:get_value(<<"index.html">>, Bundle),
    ?assert(binary:match(Index, <<"local/beam-fixtures 1.0">>) =/= nomatch),
    ?assert(binary:match(Index, <<"ldoc-fixture">>) =/= nomatch),
    ?assert(binary:match(Index, <<"<h1>API overview</h1>">>) =/= nomatch),
    ?assert(binary:match(Index, <<"<h2>Modules</h2>">>) =/= nomatch),
    ClassicName = module_html_name(<<"erlang">>, <<"ldoc_classic">>),
    ClassicHtml = proplists:get_value(ClassicName, Bundle),
    ?assert(binary:match(ClassicHtml, <<"<p>Show the input.</p>">>) =/= nomatch),
    ?assert(binary:match(ClassicHtml, <<"def-66756E6374696F6E-73686F77-1">>) =/= nomatch),
    ?assert(binary:match(ClassicHtml,
                         <<"<span class=\"library\">local/beam-fixtures</span><span class=\"version\">1.0</span><span class=\"brand-mark\">ldoc</span>">>) =/= nomatch),
    LfeHtml = proplists:get_value(module_html_name(<<"lfe">>, <<"ldoc-fixture">>), Bundle),
    ?assert(binary:match(LfeHtml, <<"One argument.">>) =/= nomatch),
    ?assert(binary:match(LfeHtml, <<"sample/1">>) =/= nomatch),
    ?assertEqual(nomatch, binary:match(LfeHtml, <<"LFE-EXPAND-EXPORTED-MACRO">>)),
    ?assertEqual(1, length(binary:matches(LfeHtml, <<"id=\"api-navigation\"">>))),
    ?assertEqual(1, length(binary:matches(LfeHtml, <<"id=\"api-filter\"">>))),
    ?assert(binary:match(LfeHtml, <<"<button class=\"menu-button\" data-menu-button hidden">>) =/= nomatch),
    ?assert(binary:match(LfeHtml, <<"id=\"api-filter\" class=\"filter\" data-filter hidden">>) =/= nomatch),
    LegacyName = module_html_name(<<"lfe">>, <<"ldoc-legacy">>),
    LegacyHtml = proplists:get_value(LegacyName, Bundle),
    LegacyNative = module_named(maps:get(modules, Retrieved1), <<"ldoc-legacy">>),
    LegacyPatterns = [Entry || Entry <- maps:get(entries, LegacyNative),
                               maps:is_key(patterns, Entry)],
    ?assertEqual(5, length(LegacyPatterns)),
    lists:foreach(
      fun(Entry) ->
          NativePatterns = unicode:characters_to_binary(
                             lfe_io:print1(maps:get(patterns, Entry)),
                             utf8, utf8),
          ExpectedPatterns = 'ldoc-markup':escape(NativePatterns),
          ?assert(binary:match(LegacyHtml, ExpectedPatterns) =/= nomatch)
      end, LegacyPatterns),
    ?assert(binary:match(LegacyHtml, <<"is_atom">>) =/= nomatch),
    ?assert(binary:match(LegacyHtml, <<"is_integer">>) =/= nomatch),
    AssetJs = proplists:get_value(<<"ldoc.js">>, Bundle),
    ?assert(binary:match(AssetJs, <<"const body">>) =/= nomatch),
    ?assertEqual(nomatch, binary:match(AssetJs, <<"var ">>)),
    EmptyTextView = html_empty_text_view(View1),
    {ok, EmptyTextBundle} = 'ldoc-html':render(EmptyTextView),
    EmptyTextHtml = proplists:get_value(module_html_name(<<"lfe">>, <<"ldoc-fixture">>),
                                        EmptyTextBundle),
    ?assert(binary:match(EmptyTextHtml,
                         <<"<p class=\"state\">Documentation text is empty.</p>">>) =/= nomatch),
    assert_html_doc_state(View1, none,
                          <<"No documentation supplied.">>),
    assert_html_doc_state(View1, hidden,
                          <<"Documentation is hidden.">>),
    assert_html_doc_state(View1, #{},
                          <<"No documentation text is available.">>),
    SecretDocset = map_entry(
                     fun(Entry) -> Entry#{doc := #{<<"en">> =>
                                                   <<"secret prose must stay private">>}}
                     end,
                     Retrieved1, <<"ldoc-fixture">>, <<"function">>,
                     <<"sample">>, 1),
    ?assertEqual(<<"secret prose must stay private">>,
                 maps:get(<<"en">>, maps:get(doc,
                     entry(maps:get(entries, module_named(
                                             maps:get(modules, SecretDocset),
                                             <<"ldoc-fixture">>)),
                           <<"function">>, <<"sample">>, 1)))),
    HiddenSecretDocset = update_module(
                           fun(Module) -> Module#{doc := hidden} end,
                           SecretDocset, <<"ldoc-fixture">>),
    {ok, HiddenModuleView} = 'ldoc-analysis':view(
                               HiddenSecretDocset,
                               #{source_root => filename:absname(Temp)}),
    {ok, HiddenModuleBundle} = 'ldoc-html':render(
                                 HiddenModuleView,
                                 #{source_base =>
                                     <<"https://example.test/declared/">>}),
    HiddenModuleHtml = proplists:get_value(
                         module_html_name(<<"lfe">>, <<"ldoc-fixture">>),
                         HiddenModuleBundle),
    ?assert(binary:match(HiddenModuleHtml,
                         <<"Documentation is hidden.">>) =/= nomatch),
    ?assertEqual(nomatch, binary:match(HiddenModuleHtml,
                                       <<"secret prose must stay private">>)),
    ?assertEqual(nomatch, binary:match(HiddenModuleHtml,
                                       <<"sample/1">>)),
    ?assertEqual(nomatch, binary:match(HiddenModuleHtml,
                                       <<"class=\"source\"">>)),
    {ok, Html0} = 'ldoc-markup':render(<<"text/markdown">>, <<"One **bold** and `code`.">>),
    ?assertEqual(<<"<p>One <strong>bold</strong> and <code>code</code>.</p>">>, Html0),
    {ok, HtmlEdoc} = 'ldoc-markup':render(<<"application/erlang+html">>,
                                          [{p, [], [<<"Show the input.">>]}]),
    ?assertEqual(<<"<p>Show the input.</p>">>, HtmlEdoc),
    {ok, PathTextHtml} = 'ldoc-markup':render(
                           <<"text/markdown">>,
                           <<"Read /tmp/example.erl and `/tmp/code path`.\nKeep it visible.">>),
    ?assert(binary:match(PathTextHtml, <<"/tmp/example.erl">>) =/= nomatch),
    ?assert(binary:match(PathTextHtml, <<"/tmp/code path">>) =/= nomatch),
    {ok, SelectedPathBundle} = 'ldoc-html':render(
                                 html_sample_doc_view(
                                   View1,
                                   #{<<"en">> =>
                                       <<"Read /tmp/example.erl and `/tmp/code path`.\nKeep both visible.">>})),
    SelectedPathHtml = proplists:get_value(
                         module_html_name(<<"lfe">>, <<"ldoc-fixture">>),
                         SelectedPathBundle),
    ?assert(binary:match(SelectedPathHtml,
                         <<"/tmp/example.erl and <code>/tmp/code path</code>">>) =/= nomatch),
    {ok, RichHtml} = 'ldoc-markup':render(
        <<"text/markdown">>,
        <<"| key | description |\n| --- | --- |\n| input | `a<b` |\n| output | **safe** |\n\n```\n<script>literal</script>\n```\n\n<script>raw</script>">>),
    ?assert(binary:match(RichHtml, <<"<table><thead><tr><th>key</th><th>description</th>">>) =/= nomatch),
    ?assert(binary:match(RichHtml, <<"&lt;script&gt;literal&lt;/script&gt;">>) =/= nomatch),
    ?assert(binary:match(RichHtml, <<"&lt;script&gt;raw&lt;/script&gt;">>) =/= nomatch),
    ?assertEqual(nomatch, binary:match(RichHtml, <<"<script>">>)),
    {ok, MultilineHtml} = 'ldoc-markup':render(
                            <<"text/markdown">>,
                            <<"A wrapped paragraph\nwith two lines.">>),
    ?assertEqual(<<"<p>A wrapped paragraph with two lines.</p>">>, MultilineHtml),
    {ok, LiteralHtml} = 'ldoc-markup':render(
                          <<"text/markdown">>,
                          <<"unclosed `code and *em and **strong and ![alt](https://example.test/x)">>),
    ?assert(binary:match(LiteralHtml, <<"unclosed `code and *em and **strong">>) =/= nomatch),
    ?assert(binary:match(LiteralHtml, <<"alt">>) =/= nomatch),
    ?assertEqual(nomatch, binary:match(LiteralHtml, <<"<img">>)),
    {ok, GroupedHtml} = 'ldoc-markup':render(
                          <<"text/markdown">>,
                          <<"7. first\n8. second\n\n- one\n+ two\n\n> quote one\n> quote two\n\n```\nunfinished">>),
    ?assertEqual(1, length(binary:matches(GroupedHtml, <<"<ol start=\"7\">">>))),
    ?assertEqual(1, length(binary:matches(GroupedHtml, <<"<ul>">>))),
    ?assertEqual(1, length(binary:matches(GroupedHtml, <<"<blockquote>">>))),
    ?assert(binary:match(GroupedHtml, <<"</code></pre>">>) =/= nomatch),
    {ok, LinkHtml} = 'ldoc-markup':render(
        <<"text/markdown">>,
        <<"See [safe](https://example.test/a%20b) and [bad](javascript:alert(1)).">>),
    ?assert(binary:match(LinkHtml,
                         <<"<a href=\"https://example.test/a%20b\">safe</a>">>) =/= nomatch),
    ?assertEqual(nomatch, binary:match(LinkHtml, <<"href=\"javascript:">>)),
    ?assert(binary:match(LinkHtml, <<"bad">>) =/= nomatch),
    {ok, ValidUriHtml} = 'ldoc-markup':render(
                           <<"text/markdown">>,
                           <<"[query](https://example.test:65535/a?q=1#part) [zero](http://example.test:0/) [opaque](https:opaque) [empty](https:///path) [high](https://example.test:65536/) [blank-port](https://example.test:/) [bad-percent](https://example.test/%GG/) [space](https://example.test/a b) [slash](https://example.test/a\\b)">>),
    ?assert(binary:match(ValidUriHtml,
                         <<"href=\"https://example.test:65535/a?q=1#part\"">>) =/= nomatch),
    ?assertEqual(2, length(binary:matches(ValidUriHtml, <<"href=\"">>))),
    {ok, HostileEdoc} = 'ldoc-markup':render(
        <<"application/erlang+html">>,
        [{script, [], [<<"unsafe">>]},
         {a, [{href, <<"javascript:alert(1)">>}], [<<"link">>]}]),
    ?assertEqual(nomatch, binary:match(HostileEdoc, <<"<script>">>)),
    ?assertEqual(nomatch, binary:match(HostileEdoc, <<"href=\"javascript:">>)),
    {ok, NestedEdoc} = 'ldoc-markup':render(
                         <<"application/erlang+html">>,
                         [{p, [], [<<"safe ">>,
                                   {a, [{href, <<"https://example.test/?q=1#part">>},
                                        {title, <<"hint">>},
                                        {id, <<"discard">>},
                                        {onclick, <<"discard">>}],
                                    [<<"link">>]}]}]),
    ?assert(binary:match(NestedEdoc,
                         <<"href=\"https://example.test/?q=1#part\" title=\"hint\"">>) =/= nomatch),
    ?assertEqual(nomatch, binary:match(NestedEdoc, <<"discard">>)),
    ?assertMatch({error, invalid_documentation},
                 'ldoc-markup':render(<<"application/erlang+html">>,
                                      [{p, malformed_attrs, [<<"x">>]}])),
    ?assertMatch({error, invalid_documentation},
                 'ldoc-markup':render(<<"application/erlang+html">>, [<<"x">> | improper])),
    ?assertEqual({error, invalid_view}, 'ldoc-html':render(#{release => maps:get(release, View1), languages => []})),
    ?assertEqual({error, invalid_view}, 'ldoc-html':render(View1#{extra => true})),
    FirstLanguage = hd(maps:get(languages, View1)),
    ?assertEqual({error, invalid_view},
                 'ldoc-html':render(View1#{languages := [FirstLanguage | improper]})),
    FirstModule = hd(maps:get(modules, FirstLanguage)),
    BadLaterModule = FirstLanguage#{modules := [FirstModule, FirstModule#{extra => true}]},
    ?assertEqual({error, invalid_view},
                 'ldoc-html':render(View1#{languages := [FirstLanguage, BadLaterModule]})),
    FirstDefinition = hd(maps:get(definitions, FirstModule)),
    BadLaterDefinition = FirstModule#{definitions :=
        [FirstDefinition, FirstDefinition#{arity := -1}]},
    BadDefinitionLanguage = FirstLanguage#{modules := [BadLaterDefinition]},
    ?assertEqual({error, invalid_view},
                 'ldoc-html':render(View1#{languages := [BadDefinitionLanguage]})),
    ?assertEqual({error, invalid_view},
                 'ldoc-html':render(View1#{languages := [FirstLanguage, 42]})),
    ?assertEqual({error, invalid_view},
                 'ldoc-html':render(html_duplicate_module_name_view(View1))),
    ?assertEqual({error, invalid_view},
                 'ldoc-html':render(html_bad_signature_view(View1))),
    ?assertEqual({error, invalid_view},
                 'ldoc-html':render(html_explicit_none_source_view(View1))),
    ?assertEqual({error, invalid_view},
                 'ldoc-html':render(html_bad_relative_source_view(View1))),
    {ok, OpaqueBundle} = 'ldoc-html':render(html_opaque_fallback_view(View1)),
    OpaqueHtml = proplists:get_value(
                   module_html_name(<<"lfe">>, <<"ldoc-fixture">>),
                   OpaqueBundle),
    ?assert(binary:match(OpaqueHtml, <<"__struct__">>) =/= nomatch),
    ?assert(binary:match(OpaqueHtml, <<"field">>) =/= nomatch),
    ?assertEqual({error, invalid_options},
                 'ldoc-html':render(#{bad => a_view}, #{unknown => true})),
    {ok, KindView} = 'ldoc-analysis':view(html_kind_arity_variant(Retrieved1)),
    {ok, KindBundle} = 'ldoc-html':render(KindView),
    KindHtml = proplists:get_value(module_html_name(<<"erlang">>, <<"ldoc_modern">>),
                                   KindBundle),
    ?assert(binary:match(KindHtml,
                         <<"function value/0">>) =/= nomatch),
    ?assert(binary:match(KindHtml,
                         <<"type value/0">>) =/= nomatch),
    ?assert(binary:match(KindHtml,
                         <<"def-66756E6374696F6E-76616C7565-0">>) =/= nomatch),
    ?assert(binary:match(KindHtml,
                         <<"def-74797065-76616C7565-0">>) =/= nomatch),
    {ok, ArityBundle} = 'ldoc-html':render(html_arity_order_view(View1)),
    ArityHtml = proplists:get_value(module_html_name(<<"lfe">>, <<"ldoc-fixture">>),
                                    ArityBundle),
    {FirstOrder, _} = binary:match(ArityHtml,
                                    <<"id=\"def-66756E6374696F6E-6F726465722D636865636B-2\"">>),
    {SecondOrder, _} = binary:match(ArityHtml,
                                     <<"id=\"def-66756E6374696F6E-6F726465722D636865636B-10\"">>),
    ?assert(FirstOrder < SecondOrder),
    ?assertMatch({ok, _}, 'ldoc-html':render(html_empty_patterns_view(View1))),
    ?assertEqual({error, invalid_options}, 'ldoc-html':render(View1, #{unknown => true})),
    ?assertEqual({error, invalid_options},
                 'ldoc-html':render(View1, #{locale => not_binary})),
    ?assertEqual({error, invalid_options},
                 'ldoc-html':render(View1, #{overview => <<255>>})),
    ?assertEqual({error, invalid_view},
                 'ldoc-html':render(View1#{languages :=
                     [FirstLanguage#{name := <<255>>} |
                      tl(maps:get(languages, View1))]})),
    URIOptions = [
        {#{source_base => <<"https://example.test/repo/">>}, ok},
        {#{source_base => <<"https://example.test:0/repo/">>}, ok},
        {#{source_base => <<"https://example.test:65535/repo/">>}, ok},
        {#{source_base => <<"HTTPS://example.test/repo/%20/">>}, ok},
        {#{source_base => <<"https://example.test:-1/">>}, invalid_options},
        {#{source_base => <<"https://example.test:65536/">>}, invalid_options},
        {#{source_base => <<"https://example.test:abc/">>}, invalid_options},
        {#{source_base => <<"https://example.test:/">>}, invalid_options},
        {#{source_base => <<"https://example.test/%/">>}, invalid_options},
        {#{source_base => <<"https://example.test/%GG/">>}, invalid_options},
        {#{source_base => <<"https://user@example.test/">>}, invalid_options},
        {#{source_base => <<"https://example.test/?query">>}, invalid_options},
        {#{source_base => <<"https://example.test/#fragment">>}, invalid_options}],
    lists:foreach(fun({Options, Expected}) ->
                      case Expected of
                          ok -> ?assertMatch({ok, _}, 'ldoc-html':render(View1, Options));
                          invalid_options -> ?assertEqual({error, invalid_options},
                                                            'ldoc-html':render(View1, Options))
                      end
                  end, URIOptions),
    SourceView = html_source_view(View1),
    {ok, SourceBundle} = 'ldoc-html':render(
                           SourceView,
                           #{source_base => <<"https://example.test/root%20/">>}),
    SourceHtml = proplists:get_value(module_html_name(<<"lfe">>, <<"ldoc-fixture">>),
                                     SourceBundle),
    ?assert(binary:match(SourceHtml,
                         <<"https://example.test/root%20/src/a%20%25%3F%23%22%C3%A9.erl#L71">>) =/= nomatch),
    {ok, NoBaseBundle} = 'ldoc-html':render(SourceView),
    ?assertEqual(nomatch, binary:match(
                            proplists:get_value(
                              module_html_name(<<"lfe">>, <<"ldoc-fixture">>),
                              NoBaseBundle),
                            <<"class=\"source\"">>)),
    {ok, GenuineSourcedView} = 'ldoc-analysis':view(
                                 Retrieved1,
                                 #{source_root => filename:absname(Temp)}),
    {ok, GenuineSourceBundle} = 'ldoc-html':render(
                                  GenuineSourcedView,
                                  #{source_base =>
                                      <<"https://example.test/tree/">>}),
    GenuineModernHtml = proplists:get_value(
                          module_html_name(<<"erlang">>, <<"ldoc_modern">>),
                          GenuineSourceBundle),
    assert_native_modern_source_html(
      GenuineModernHtml, Docset1, filename:absname(Temp),
      <<"https://example.test/tree/">>),
    GenuineClassicHtml = proplists:get_value(
                           module_html_name(<<"erlang">>, <<"ldoc_classic">>),
                           GenuineSourceBundle),
    ?assert(binary:match(GenuineClassicHtml,
                         <<"https://example.test/tree/ldoc_classic.erl#L2">>) =/= nomatch),
    ?assert(binary:match(GenuineClassicHtml,
                         <<"https://example.test/tree/ldoc_classic.erl#L7">>) =/= nomatch),
    GenuineLfeHtml = proplists:get_value(
                       module_html_name(<<"lfe">>, <<"ldoc-fixture">>),
                       GenuineSourceBundle),
    ?assertEqual(nomatch, binary:match(GenuineLfeHtml,
                                       <<"class=\"source\"">>)),
    ?assertMatch({ok, _}, 'ldoc-html':render(View2)),
    RichView = html_rich_view(SourceView),
    {ok, RichBundle} = 'ldoc-html':render(
                         RichView,
                         #{source_base => <<"https://example.test/root%20/">>,
                           overview =>
                             <<"# Controlled ldoc specimen\n\nThis first overview paragraph explains that the specimen uses original prose to make the page hierarchy and line rhythm inspectable. It is a controlled browser fixture, not compiler-generated documentation.\n\nA second paragraph describes the native four-route population and the navigation affordances available to a reader.\n\n## Reading the reference\n\n- follow a module link\n- filter a definition\n\nThe inline token `reference-view` remains literal code.\n\n```\nrender(View, Options)\n```">>}),
    RichIndex = proplists:get_value(<<"index.html">>, RichBundle),
    ?assert(binary:match(RichIndex, <<"Controlled ldoc specimen">>) =/= nomatch),
    ?assertEqual(nomatch, binary:match(RichIndex,
                                       <<"<h1>API overview</h1>">>)),
    ?assert(binary:match(RichIndex, <<"<ul>">>) =/= nomatch),
    ?assert(binary:match(RichIndex, <<"<pre><code>">>) =/= nomatch),
    RichModuleHtml = proplists:get_value(
                       module_html_name(<<"lfe">>, <<"ldoc-fixture">>),
                       RichBundle),
    ?assert(binary:match(RichModuleHtml,
                         <<"Rich original specimen">>) =/= nomatch),
    ?assert(binary:match(RichModuleHtml, <<"<ul>">>) =/= nomatch),
    ?assert(binary:match(RichModuleHtml, <<"<blockquote>">>) =/= nomatch),
    ?assert(binary:match(RichModuleHtml, <<"<table>">>) =/= nomatch),
    ?assert(binary:match(RichModuleHtml, <<"<pre><code>">>) =/= nomatch),
    ?assert(binary:match(RichModuleHtml,
                         <<"<pre class=\"signature\"><code>sample(Input)</code></pre>">>) =/= nomatch),
    ?assert(binary:match(RichModuleHtml,
                         <<"<pre class=\"signature\"><code>sample(Input, Options)\n    when is_integer(Options)</code></pre>">>) =/= nomatch),
    ?assert(binary:match(RichModuleHtml,
                         <<"long_identifier_for_responsive_wrapping_and_navigation_filtering_0123456789">>) =/= nomatch),
    ?assertEqual(3, length(binary:matches(RichModuleHtml, <<"<tr>">>))),
    ?assert(binary:match(RichModuleHtml,
                         <<"sample(Input, Options)">>) =/= nomatch),
    {ok, UnclosedFenceBundle} = 'ldoc-html':render(
                                 html_unclosed_fence_view(View1)),
    UnclosedFenceHtml = proplists:get_value(
                          module_html_name(<<"lfe">>, <<"ldoc-fixture">>),
                          UnclosedFenceBundle),
    ?assert(binary:match(UnclosedFenceHtml,
                         <<"unfinished\n</code></pre></div>">>) =/= nomatch),
    LocaleCases = [
        {<<"en">>, true},
        {<<"en-US">>, true},
        {<<"sr-Latn">>, true},
        {<<"es-419">>, true},
        {<<"zh-Hant-TW">>, true},
        {<<"123">>, false},
        {<<"-">>, false},
        {<<"en--US">>, false},
        {<<"en-">>, false},
        {<<"-en">>, false},
        {<<"arbitrary-key">>, false},
        {<<"unknown">>, false},
        {<<"und">>, false},
        {<<"UND">>, false}],
    lists:foreach(
      fun({Locale, Annotated}) ->
          LocaleView = html_sample_doc_view(
                         View1,
                         #{Locale => <<"Locale witness remains selected.">>}),
          {ok, LocaleBundle} = 'ldoc-html':render(
                                 LocaleView, #{locale => Locale}),
          LocaleHtml = proplists:get_value(
                         module_html_name(<<"lfe">>, <<"ldoc-fixture">>),
                         LocaleBundle),
          ?assert(binary:match(LocaleHtml,
                               <<"Locale witness remains selected.">>) =/= nomatch),
          LangAttribute = <<"lang=\"", Locale/binary, "\"">>,
          case Annotated of
              true -> ?assert(binary:match(LocaleHtml, LangAttribute) =/= nomatch);
              false -> ?assertEqual(nomatch,
                                    binary:match(LocaleHtml, LangAttribute))
          end
      end, LocaleCases),
    {ok, After1} = 'ldoc-store':get(StoreRoot, Release1),
    {ok, After2} = 'ldoc-store':get(StoreRoot, Release2),
    ?assertEqual(BeforeTerm1, {ok, After1}),
    ?assertEqual(BeforeTerm2, {ok, After2}),
    ?assertEqual(Docset1, After1),
    ?assertEqual(Docset2, After2),
    ?assertEqual(BeforeBytes1, file:read_file(store_path(StoreRoot, Release1))),
    ?assertEqual(BeforeBytes2, file:read_file(store_path(StoreRoot, Release2))),
    ok.

html_section_ids(Html) ->
    {match, Matches} = re:run(Html, <<"id=\"(def-[^\"]+)\"">>,
                              [global, {capture, [1], binary}]),
    [Id || [Id] <- Matches].

html_expected_definition_ids(View) ->
    [html_definition_id(Definition) || Language <- maps:get(languages, View),
        Module <- maps:get(modules, Language),
        Definition <- maps:get(definitions, Module)].

reverse_html_view(View) ->
    Languages = [Language#{modules :=
                    [Module#{definitions := lists:reverse(
                                                maps:get(definitions, Module))}
                     || Module <- lists:reverse(maps:get(modules, Language))]}
                 || Language <- lists:reverse(maps:get(languages, View))],
    View#{languages := Languages}.

assert_html_doc_state(View, DocValue, Expected) ->
    StateView = html_sample_doc_view(View, DocValue),
    {ok, Bundle} = 'ldoc-html':render(StateView),
    Html = proplists:get_value(module_html_name(<<"lfe">>, <<"ldoc-fixture">>),
                               Bundle),
    ?assert(binary:match(Html, Expected) =/= nomatch).

html_sample_doc_view(View, DocValue) ->
    update_html_sample_module(
      View,
      fun(Module) ->
          Module#{definitions :=
            [case {maps:get(name, Definition), maps:get(arity, Definition)} of
                 {<<"sample">>, 1} -> Definition#{doc := DocValue};
                 _ -> Definition
             end || Definition <- maps:get(definitions, Module)]}
      end).

update_html_sample_module(View, Fun) ->
    Languages = [case maps:get(name, Language) of
        <<"lfe">> ->
            Language#{modules :=
              [case maps:get(name, Module) of
                   <<"ldoc-fixture">> -> Fun(Module);
                   _ -> Module
               end || Module <- maps:get(modules, Language)]};
        _ -> Language
    end || Language <- maps:get(languages, View)],
    View#{languages := Languages}.

html_duplicate_module_name_view(View) ->
    [First, Second | Rest] = maps:get(languages, View),
    Duplicate = hd(maps:get(modules, First)),
    View#{languages := [First,
                        Second#{modules := [Duplicate | maps:get(modules, Second)]}
                        | Rest]}.

html_bad_signature_view(View) ->
    update_html_sample_module(
      View,
      fun(Module) ->
          [Definition | Rest] = maps:get(definitions, Module),
          Module#{definitions := [Definition#{signatures := [not_binary]} | Rest]}
      end).

html_explicit_none_source_view(View) ->
    update_html_sample_module(View, fun(Module) -> Module#{source => none} end).

html_bad_relative_source_view(View) ->
    update_html_sample_module(
      View, fun(Module) -> Module#{source => #{path => <<"../secret.erl">>}} end).

html_opaque_fallback_view(View) ->
    update_html_sample_module(
      View,
      fun(Module) ->
          Module#{format := <<"application/x-native-term">>,
                  doc := #{<<"en">> =>
                             #{'__struct__' => <<"ordinary-map">>, field => 42}},
                  definitions := [Definition#{patterns =>
                    #{'__struct__' => <<"ordinary-pattern-map">>, field => 7}} ||
                                    Definition <- maps:get(definitions, Module)]}
      end).

html_kind_arity_variant(Docset) ->
    Module = module_named(maps:get(modules, Docset), <<"ldoc_modern">>),
    Type = entry(maps:get(entries, Module), <<"type">>, <<"value">>, 0),
    Function = Type#{kind := <<"function">>, doc := none, signatures := []},
    update_module(
      fun(Current) ->
          Current#{entries := [Function | maps:get(entries, Current)]}
      end,
      Docset, <<"ldoc_modern">>).

html_arity_order_view(View) ->
    update_html_sample_module(
      View,
      fun(Module) ->
          Template = hd(maps:get(definitions, Module)),
          Order10 = Template#{name := <<"order-check">>, arity := 10,
                              signatures := [], doc := none},
          Order2 = Template#{name := <<"order-check">>, arity := 2,
                             signatures := [], doc := none},
          Module#{definitions := [Order10, Order2 | maps:get(definitions, Module)]}
      end).

html_empty_patterns_view(View) ->
    update_html_sample_module(
      View,
      fun(Module) ->
          [Definition | Rest] = maps:get(definitions, Module),
          Module#{definitions := [Definition#{patterns => []} | Rest]}
      end).

html_unclosed_fence_view(View) ->
    update_html_sample_module(
      View,
      fun(Module) ->
          Module#{definitions :=
            [case {maps:get(name, Definition), maps:get(arity, Definition)} of
                 {<<"sample">>, 1} ->
                     Definition#{doc := #{<<"en">> =>
                         <<"Unclosed fence:\n\n```\nunfinished">>}};
                 _ -> Definition
             end || Definition <- maps:get(definitions, Module)]}
      end).

html_definition_id(Definition) ->
    Kind = list_to_binary(string:uppercase(
                            binary_to_list(binary:encode_hex(
                                             maps:get(kind, Definition))))),
    Name = list_to_binary(string:uppercase(
                            binary_to_list(binary:encode_hex(
                                             maps:get(name, Definition))))),
    Arity = case maps:get(arity, Definition) of
                unknown -> "unknown";
                Number -> integer_to_list(Number)
            end,
    <<"def-", Kind/binary, "-", Name/binary, "-", (list_to_binary(Arity))/binary>>.

module_html_name(Language, Module) ->
    DigestInput = <<(byte_size(Language)):32/big, Language/binary,
                    (byte_size(Module)):32/big, Module/binary>>,
    Digest = crypto:hash(sha256, DigestInput),
    Hex = list_to_binary(string:uppercase(binary_to_list(binary:encode_hex(Digest)))),
    <<"m-", Hex/binary, ".html">>.

html_empty_text_view(View) ->
    Languages = maps:get(languages, View),
    UpdatedLanguages = [case maps:get(name, Language) of
        <<"lfe">> ->
            Modules = maps:get(modules, Language),
            UpdatedModules = [case maps:get(name, Module) of
                <<"ldoc-fixture">> ->
                    Definitions = maps:get(definitions, Module),
                    UpdatedDefinitions = [case {maps:get(name, Definition), maps:get(arity, Definition)} of
                        {<<"sample">>, 1} -> Definition#{doc := #{<<"en">> => <<>>}};
                        _ -> Definition
                    end || Definition <- Definitions],
                    Module#{definitions := UpdatedDefinitions};
                _ -> Module
            end || Module <- Modules],
            Language#{modules := UpdatedModules};
        _ -> Language
    end || Language <- Languages],
    View#{languages := UpdatedLanguages}.

html_source_view(View) ->
    Languages = maps:get(languages, View),
    Lfe = lists:keyfind(<<"lfe">>, 1,
                        [{maps:get(name, L), L} || L <- Languages]),
    {_, LfeLanguage} = Lfe,
    Modules = maps:get(modules, LfeLanguage),
    Fixture = hd([M || M <- Modules, maps:get(name, M) =:= <<"ldoc-fixture">>]),
    Definitions = maps:get(definitions, Fixture),
    Sample = hd([D || D <- Definitions,
                      maps:get(name, D) =:= <<"sample">>,
                      maps:get(arity, D) =:= 1]),
    SourcePath = unicode:characters_to_binary("src/a %?#\"é.erl"),
    Source = #{path => SourcePath, line => 71},
    UpdatedDefinition = Sample#{source => Source},
    UpdatedDefinitions = [case D =:= Sample of true -> UpdatedDefinition; false -> D end
                          || D <- Definitions],
    UpdatedModule = Fixture#{source => Source, definitions => UpdatedDefinitions},
    UpdatedModules = [case M =:= Fixture of true -> UpdatedModule; false -> M end
                      || M <- Modules],
    UpdatedLanguage = LfeLanguage#{modules => UpdatedModules},
    UpdatedLanguages = [case L =:= LfeLanguage of true -> UpdatedLanguage; false -> L end
                        || L <- Languages],
    View#{languages => UpdatedLanguages}.

html_rich_view(View) ->
    Languages = maps:get(languages, View),
    UpdatedLanguages = [case maps:get(name, Language) of
        <<"lfe">> ->
            Modules = maps:get(modules, Language),
            UpdatedModules = [case maps:get(name, Module) of
                <<"ldoc-fixture">> ->
                    Definitions = maps:get(definitions, Module),
                    UpdatedDefinitions = [case {maps:get(name, Definition), maps:get(arity, Definition)} of
                        {<<"sample">>, 1} -> Definition#{
                            signatures := [<<"sample(Input)">>,
                                           <<"sample(Input, Options)\n    when is_integer(Options)">>],
                            doc := #{<<"en">> =>
                            <<"# Rich original specimen\n\nThis first paragraph introduces a longer, original API narrative. It explains the input contract, the result shape, and the boundary between stored facts and the browser view.\n\nThis second paragraph gives the reader another continuous block of prose so the article width and line rhythm can be inspected at a realistic density.\n\n## A smaller heading\n\n- first item\n- second item\n\n> A quoted note with enough text to show the quote measure in context.\n\n| input | output |\n| --- | --- |\n| `a<b` | **safe** |\n| `count` | `3` |\n\n[reference](https://example.test/docs) and [rejected](javascript:alert(1)).\n\n```\n<sample input=\"safe\" />\n```\n\n<script>raw</script>">>}};
                        _ -> Definition
                    end || Definition <- Definitions],
                    Template = hd(Definitions),
                    LongIdentifier = Template#{
                        name := <<"long_identifier_for_responsive_wrapping_and_navigation_filtering_0123456789">>,
                        arity := 0,
                        signatures := [<<"long_identifier_for_responsive_wrapping_and_navigation_filtering_0123456789()">>],
                        doc := none},
                    Module#{definitions := [LongIdentifier | UpdatedDefinitions]};
                _ -> Module
            end || Module <- Modules],
            Language#{modules := UpdatedModules};
        _ -> Language
    end || Language <- Languages],
    View#{languages := UpdatedLanguages}.

analysis_app_contract() ->
    AppPath = code:where_is_file("ldoc.app"),
    {ok, [{application, ldoc, Properties}]} = file:consult(AppPath),
    Modules = proplists:get_value(modules, Properties),
    ?assert(lists:member('ldoc-analysis', Modules)),
    ?assert(lists:member(ldoc_project_pages, Modules)),
    Applications = proplists:get_value(applications, Properties),
    ?assert(lists:member(lfe, Applications)),
    ?assert(lists:member(crypto, Applications)),
    Exports = 'ldoc-analysis':module_info(exports),
    PublicExports = lists:sort(
                      [Export || Export = {Name, _Arity} <- Exports,
                                 Name =/= '__info__',
                                 Name =/= 'LFE-EXPAND-EXPORTED-MACRO',
                                 Name =/= module_info]),
    ?assertEqual([{'valid-options?', 1}, {view, 1}, {view, 2}], PublicExports),
    HtmlExports = 'ldoc-html':module_info(exports),
    HtmlPublicExports = lists:sort(
                          [Export || Export = {Name, _Arity} <- HtmlExports,
                                     Name =/= '__info__',
                                     Name =/= 'LFE-EXPAND-EXPORTED-MACRO',
                                     Name =/= module_info]),
    ?assertEqual([{render, 1}, {render, 2}, {'valid-options?', 1}],
                 HtmlPublicExports),
    ?assert(lists:member('ldoc-site', Modules)),
    SiteExports = 'ldoc-site':module_info(exports),
    SitePublicExports = lists:sort(
                          [Export || Export = {Name, _Arity} <- SiteExports,
                                     Name =/= '__info__',
                                     Name =/= 'LFE-EXPAND-EXPORTED-MACRO',
                                     Name =/= module_info]),
    ?assertEqual([{build, 3}, {build, 4}], SitePublicExports),
    ?assertEqual([{load, 4}],
                 [Export || Export = {Name, _} <- ldoc_project_pages:module_info(exports),
                            Name =/= module_info]),
    assert_native_boolean_spec('ldoc-docset', 'valid-release?', 1),
    assert_native_boolean_spec('ldoc-analysis', 'valid-options?', 1),
    assert_native_boolean_spec('ldoc-html', 'valid-options?', 1),
    lists:foreach(fun({Module, Name, Arity}) ->
        assert_native_spec(Module, Name, Arity)
    end, [{'ldoc-pages', prepare, 2},
          {'ldoc-pages', 'prepare-graph', 1},
          {'ldoc-pages', route, 1},
          {'ldoc-pages', 'canonical-path', 1},
          {ldoc_project_pages, load, 4},
          {'ldoc-markup', scan, 1},
          {'ldoc-markup', render, 3}]),
    ?assert('ldoc-docset':'valid-release?'(
              #{namespace => <<"local">>, package => <<"pkg">>, version => <<"1">>})),
    ?assertNot('ldoc-docset':'valid-release?'(
                 #{namespace => <<"local">>, package => <<"pkg">>})),
    ?assert('ldoc-analysis':'valid-options?'(#{})),
    ?assertNot('ldoc-analysis':'valid-options?'(#{source_root => "relative"})),
    ?assert('ldoc-html':'valid-options?'(#{})),
    ?assertNot('ldoc-html':'valid-options?'(#{version_index => invalid})),
    ok.

assert_native_boolean_spec(Module, Name, Arity) ->
    Beam = code:which(Module),
    {ok, {Module, [{abstract_code, {raw_abstract_v1, Forms}}]}} =
        beam_lib:chunks(Beam, [abstract_code]),
    [SpecForms] = [Types ||
                      {attribute, _, spec, {{SpecName, SpecArity}, Types}} <- Forms,
                      SpecName =:= Name, SpecArity =:= Arity],
    [{type, _, 'fun', [{type, _, product, _Args}, ReturnType]}] = SpecForms,
    ?assertMatch({type, _, boolean, []}, ReturnType),
    ?assertNotMatch({atom, _, boolean}, ReturnType).

assert_native_spec(Module, Name, Arity) ->
    Beam = code:which(Module),
    {ok, {Module, [{abstract_code, {raw_abstract_v1, Forms}}]}} =
        beam_lib:chunks(Beam, [abstract_code]),
    [SpecForms] = [Types ||
                      {attribute, _, spec, {{SpecName, SpecArity}, Types}} <- Forms,
                      SpecName =:= Name, SpecArity =:= Arity],
    [{type, _, 'fun', [{type, _, product, Args}, _ReturnType]}] = SpecForms,
    ?assertEqual(Arity, length(Args)).

site_s01_s06(Temp, StoreRoot, Retrieved1, Retrieved2, View1, View2) ->
    Release1 = maps:get(release, Retrieved1),
    Release2 = maps:get(release, Retrieved2),
    Route1 = site_release_route(Release1),
    Route2 = site_release_route(Release2),
    ?assertNotEqual(Route1, Route2),
    Before1 = 'ldoc-store':get(StoreRoot, Release1),
    Before2 = 'ldoc-store':get(StoreRoot, Release2),
    BeforeBytes1 = file:read_file(store_path(StoreRoot, Release1)),
    BeforeBytes2 = file:read_file(store_path(StoreRoot, Release2)),
    Spec1 = #{release => Release1,
              overview => <<"# First exact release\n\nOriginal catalogue prose.">>,
              source_root => filename:absname(Temp),
              source_base => <<"https://example.test/source/">>},
    Spec2 = #{release => Release2,
              overview => <<"# Second exact release\n\nSeparate release text.">>},
    ForwardTarget = filename:join(Temp, "site-forward"),
    ReverseTarget = filename:join(Temp, "site-reverse"),
    {ok, ForwardIndex} = 'ldoc-site':build(
                           StoreRoot, [Spec2, Spec1], ForwardTarget),
    {ok, ReverseIndex} = 'ldoc-site':build(
                           StoreRoot, [Spec1, Spec2], ReverseTarget),
    ?assertEqual(unicode:characters_to_binary(
                   filename:join(ForwardTarget, "index.html")), ForwardIndex),
    ?assertEqual(unicode:characters_to_binary(
                   filename:join(ReverseTarget, "index.html")), ReverseIndex),
    ForwardTree = site_tree_snapshot(ForwardTarget),
    ReverseTree = site_tree_snapshot(ReverseTarget),
    ?assertEqual(16, length(ForwardTree)),
    ?assertEqual(ForwardTree, ReverseTree),
    DocsTarget = filename:join(Temp, "site-with-docs"),
    DocsSpec = Spec1#{pages => [#{path => <<"docs/guide.md">>,
                                  title => <<"Guide">>,
                                  body => <<"# Start\n\nA portable page.">>}]},
    {ok, _DocsIndex} = 'ldoc-site':build(StoreRoot, [DocsSpec], DocsTarget),
    DocsRoute = 'ldoc-pages':route(<<"docs/guide.md">>),
    {ok, DocsHtml} = file:read_file(filename:join(DocsTarget,
                                      filename:join(binary_to_list(Route1),
                                                    binary_to_list(DocsRoute)))),
    ?assert(binary:match(DocsHtml, <<"A portable page.">>) =/= nomatch),
    FailedDocsTarget = filename:join(Temp, "site-bad-doc-link"),
    BadDocsSpec = Spec1#{pages => [#{path => <<"docs/bad.md">>,
                                     body => <<"[missing](missing.md)">>}]},
    ?assertMatch({error, {release, Release1, render,
                          {documentation_link, #{href := <<"missing.md">>}}}},
                 'ldoc-site':build(StoreRoot, [BadDocsSpec], FailedDocsTarget)),
    ?assertEqual({error, enoent}, file:read_file_info(FailedDocsTarget)),
    ForwardNames = [Name || {Name, _} <- ForwardTree],
    ExpectedNames = lists:sort(
                      [<<"index.html">>, <<"ldoc.css">>,
                       <<Route1/binary, "/index.html">>,
                       <<Route1/binary, "/ldoc.css">>,
                       <<Route1/binary, "/ldoc.js">>,
                       <<Route2/binary, "/index.html">>,
                       <<Route2/binary, "/ldoc.css">>,
                       <<Route2/binary, "/ldoc.js">>] ++
                      [<<Route/binary, "/", (module_html_name(Language, Module))/binary>>
                       || {Route, Language, Module} <-
                            [{Route1, <<"erlang">>, <<"ldoc_classic">>},
                             {Route1, <<"erlang">>, <<"ldoc_modern">>},
                             {Route1, <<"lfe">>, <<"ldoc-fixture">>},
                             {Route1, <<"lfe">>, <<"ldoc-legacy">>},
                             {Route2, <<"erlang">>, <<"ldoc_classic">>},
                             {Route2, <<"erlang">>, <<"ldoc_modern">>},
                             {Route2, <<"lfe">>, <<"ldoc-fixture">>},
                             {Route2, <<"lfe">>, <<"ldoc-legacy">>}]]),
    ?assertEqual(ExpectedNames, ForwardNames),
    lists:foreach(
      fun({Route, View}) ->
          DefinitionIds = lists:sort(lists:append(
            [html_section_ids(Bytes) || {Name, Bytes} <- ForwardTree,
                has_binary_prefix(Name, <<Route/binary, "/m-">>),
                filename:extension(Name) =:= <<".html">>])),
          ?assertEqual(14, length(DefinitionIds)),
          ?assertEqual(lists:sort(html_expected_definition_ids(View)),
                       DefinitionIds)
      end, [{Route1, View1}, {Route2, View2}]),
    Catalogue = proplists:get_value(<<"index.html">>, ForwardTree),
    ?assert(binary:match(Catalogue, <<"<h1>Release catalogue</h1>">>) =/= nomatch),
    ?assert(binary:match(Catalogue,
                         <<"<main id=\"main\" class=\"content\" tabindex=\"-1\">">>) =/= nomatch),
    ?assert(binary:match(Catalogue,
                         <<Route1/binary, "/index.html\">1.0</a>">>) =/= nomatch),
    ?assert(binary:match(Catalogue,
                         <<Route2/binary, "/index.html\">v1.0</a>">>) =/= nomatch),
    {Position1, _} = binary:match(Catalogue, <<Route1/binary, "/index.html\">1.0</a>">>),
    {Position2, _} = binary:match(Catalogue, <<Route2/binary, "/index.html\">v1.0</a>">>),
    ?assert(Position1 < Position2),
    lists:foreach(
      fun({Route, Version}) ->
          HtmlNames = [Name || Name <- ForwardNames,
                               has_binary_prefix(Name, <<Route/binary, "/">>),
                               filename:extension(Name) =:= <<".html">>],
          ?assertEqual(5, length(HtmlNames)),
          lists:foreach(
            fun(Name) ->
                Html = proplists:get_value(Name, ForwardTree),
                VersionLink = <<"<a class=\"version\" href=\"../index.html\" aria-label=\"Choose exact release ",
                                Version/binary, "\">", Version/binary, "</a>">>,
                ?assert(binary:match(Html, VersionLink) =/= nomatch)
            end, HtmlNames)
      end, [{Route1, maps:get(version, Release1)},
            {Route2, maps:get(version, Release2)}]),
    Modern = proplists:get_value(
               <<Route1/binary, "/", (module_html_name(<<"erlang">>,
                                                          <<"ldoc_modern">>))/binary>>,
               ForwardTree),
    assert_native_modern_source_html(
      Modern, Retrieved1, filename:absname(Temp),
      <<"https://example.test/source/">>),
    Classic = proplists:get_value(
                <<Route1/binary, "/", (module_html_name(<<"erlang">>,
                                                           <<"ldoc_classic">>))/binary>>,
                ForwardTree),
    ?assert(binary:match(Classic,
                         <<"https://example.test/source/ldoc_classic.erl#L2">>) =/= nomatch),
    ?assert(binary:match(Classic,
                         <<"https://example.test/source/ldoc_classic.erl#L7">>) =/= nomatch),
    OtherModern = proplists:get_value(
                    <<Route2/binary, "/", (module_html_name(<<"erlang">>,
                                                               <<"ldoc_modern">>))/binary>>,
                    ForwardTree),
    ?assertEqual(nomatch, binary:match(OtherModern, <<"class=\"source\"">>)),
    DefaultTarget = filename:join(Temp, "site-default-options"),
    {ok, _} = 'ldoc-site':build(
                StoreRoot,
                [#{release => Release1}, #{release => Release2}],
                DefaultTarget),
    DefaultTree = site_tree_snapshot(DefaultTarget),
    ?assertEqual(16, length(DefaultTree)),
    LocaleTarget = filename:join(Temp, "site-locale-option"),
    {ok, _} = 'ldoc-site':build(
                StoreRoot, [#{release => Release1}], LocaleTarget,
                #{locale => <<"en">>}),
    ?assertEqual(9, length(site_tree_snapshot(LocaleTarget))),
    {ok, DefaultView1} = 'ldoc-analysis':view(Retrieved1),
    {ok, DefaultRender1} = 'ldoc-html':render(DefaultView1),
    {ok, DefaultAgain1} = 'ldoc-html':render(DefaultView1, #{version_index => false}),
    ?assertEqual(DefaultRender1, DefaultAgain1),
    {ok, LinkedRender1} = 'ldoc-html':render(DefaultView1, #{version_index => true}),
    DefaultPage = proplists:get_value(<<"index.html">>, DefaultRender1),
    LinkedPage = proplists:get_value(<<"index.html">>, LinkedRender1),
    ?assert(binary:match(DefaultPage, <<"<span class=\"version\">1.0</span>">>) =/= nomatch),
    ?assert(binary:match(LinkedPage,
                         <<"<a class=\"version\" href=\"../index.html\" aria-label=\"Choose exact release 1.0\">1.0</a>">>) =/= nomatch),
    ?assert('ldoc-html':'valid-options?'(#{})),
    ?assert('ldoc-html':'valid-options?'(#{version_index => true})),
    ?assertNot('ldoc-html':'valid-options?'(#{version_index => invalid})),
    ?assert('ldoc-analysis':'valid-options?'(#{})),
    ?assertNot('ldoc-analysis':'valid-options?'(#{source_root => "relative"})),
    site_invalid_inputs(StoreRoot, Temp, Release1),
    site_existing_targets(StoreRoot, Temp, [Spec1, Spec2]),
    site_concurrent_build(StoreRoot, Temp, [Spec1, Spec2]),
    WeirdRelease = #{namespace => <<"local & </h2>">>,
                     package => <<"pkg/../?">>,
                     version => unicode:characters_to_binary("é&v")},
    WeirdDocset = Retrieved1#{release := WeirdRelease},
    ok = 'ldoc-store':put(StoreRoot, WeirdDocset),
    BeforeWeirdBytes = file:read_file(store_path(StoreRoot, WeirdRelease)),
    WeirdTarget = filename:join(Temp, "site-hostile-labels"),
    {ok, _} = 'ldoc-site':build(
                StoreRoot,
                [#{release => WeirdRelease}, #{release => Release1}],
                WeirdTarget),
    WeirdTree = site_tree_snapshot(WeirdTarget),
    WeirdCatalogue = proplists:get_value(<<"index.html">>, WeirdTree),
    ?assert(binary:match(WeirdCatalogue,
                         <<"local &amp; &lt;/h2&gt;/pkg/../?">>) =/= nomatch),
    ?assertNot(binary:match(WeirdCatalogue, <<"<h2>local & </h2>">>) =/= nomatch),
    ?assertEqual(16, length(WeirdTree)),
    {ok, _} = 'ldoc-html':render(View2),
    {ok, After1} = 'ldoc-store':get(StoreRoot, Release1),
    {ok, After2} = 'ldoc-store':get(StoreRoot, Release2),
    {ok, AfterWeird} = 'ldoc-store':get(StoreRoot, WeirdRelease),
    ?assertEqual(element(2, Before1), After1),
    ?assertEqual(element(2, Before2), After2),
    ?assertEqual(WeirdDocset, AfterWeird),
    ?assertEqual(BeforeBytes1, file:read_file(store_path(StoreRoot, Release1))),
    ?assertEqual(BeforeBytes2, file:read_file(store_path(StoreRoot, Release2))),
    ?assertEqual(BeforeWeirdBytes,
                 file:read_file(store_path(StoreRoot, WeirdRelease))),
    Index1 = consumer_index(View1),
    Index2 = consumer_index(View2),
    ?assertEqual(2, maps:get(language_count, Index1)),
    ?assertEqual(2, maps:get(language_count, Index2)),
    ?assertEqual(4, maps:get(module_count, Index1)),
    ?assertEqual(4, maps:get(module_count, Index2)),
    ?assertEqual(14, maps:size(maps:get(definitions, Index1))),
    ?assertEqual(14, maps:size(maps:get(definitions, Index2))),
    ok.

site_invalid_inputs(StoreRoot, Temp, Release) ->
    Target = filename:join(Temp, "site-invalid-target"),
    ?assertEqual({error, invalid_options},
                 'ldoc-site':build(<<>>, [], "relative", #{unknown => true})),
    ?assertEqual({error, invalid_store_root},
                 'ldoc-site':build(<<>>, [], "relative")),
    ?assertEqual({error, invalid_target},
                 'ldoc-site':build(StoreRoot, [], "relative")),
    ?assertEqual({error, invalid_target},
                 'ldoc-site':build(StoreRoot, [], filename:absname("/"))),
    ?assertEqual({error, invalid_releases},
                 'ldoc-site':build(StoreRoot, [], Target)),
    Good = #{release => Release},
    BadRelease = #{namespace => <<255>>, package => <<"p">>, version => <<"1">>},
    ?assertEqual({error, invalid_releases},
                 'ldoc-site':build(StoreRoot,
                                   [Good, Good, #{release => BadRelease}], Target)),
    ?assertEqual({error, {duplicate_release, Release}},
                 'ldoc-site':build(StoreRoot, [Good, Good], Target)),
    ?assertEqual({error, invalid_releases},
                 'ldoc-site':build(StoreRoot,
                                   [#{release => Release, source_root => "relative"}],
                                   Target)),
    ?assertEqual({error, invalid_releases},
                 'ldoc-site':build(StoreRoot,
                                   [#{release => Release,
                                      source_base => <<"https:opaque/">>}],
                                   Target)),
    ?assertEqual({error, invalid_releases},
                 'ldoc-site':build(StoreRoot,
                                   [#{release => Release, overview => <<255>>}],
                                   Target)),
    ?assertEqual({error, {release, Release, store, not_found}},
                 'ldoc-site':build(filename:join(Temp, "missing-store"),
                                   [Good], Target)),
    MissingParent = unicode:characters_to_binary(
                      filename:join(Temp, "missing-parent")),
    ?assertEqual({error, {output, parent, MissingParent, enoent}},
                 'ldoc-site':build(StoreRoot, [Good],
                                   filename:join([Temp, "missing-parent", "site"]))),
    ?assertEqual({error, enoent}, file:read_link_info(Target)),
    ok.

site_existing_targets(StoreRoot, Temp, Specs) ->
    FileTarget = filename:join(Temp, "site-existing-file"),
    FileBytes = <<"existing file stays byte-for-byte">>,
    ok = file:write_file(FileTarget, FileBytes),
    ?assertEqual({error, output_exists},
                 'ldoc-site':build(StoreRoot, Specs, FileTarget)),
    ?assertEqual({ok, FileBytes}, file:read_file(FileTarget)),
    DirTarget = filename:join(Temp, "site-existing-directory"),
    ok = file:make_dir(DirTarget),
    ok = file:make_dir(filename:join(DirTarget, "keep")),
    ok = file:write_file(filename:join([DirTarget, "keep", "sentinel"]),
                         <<"directory sentinel">>),
    DirBefore = site_tree_snapshot(DirTarget),
    ?assertEqual({error, output_exists},
                 'ldoc-site':build(StoreRoot, Specs, DirTarget)),
    ?assertEqual(DirBefore, site_tree_snapshot(DirTarget)),
    Sentinel = filename:join(Temp, "site-link-sentinel"),
    ok = file:write_file(Sentinel, <<"symlink target bytes">>),
    LiveLink = filename:join(Temp, "site-live-symlink"),
    ok = file:make_symlink(Sentinel, LiveLink),
    {ok, LiveTarget} = file:read_link(LiveLink),
    ?assertEqual({error, output_exists},
                 'ldoc-site':build(StoreRoot, Specs, LiveLink)),
    ?assertEqual({ok, LiveTarget}, file:read_link(LiveLink)),
    ?assertEqual({ok, <<"symlink target bytes">>}, file:read_file(Sentinel)),
    Dangling = filename:join(Temp, "site-dangling-symlink"),
    ok = file:make_symlink("site-never-created", Dangling),
    {ok, DanglingTarget} = file:read_link(Dangling),
    ?assertEqual({error, output_exists},
                 'ldoc-site':build(StoreRoot, Specs, Dangling)),
    ?assertEqual({ok, DanglingTarget}, file:read_link(Dangling)),
    ok.

site_concurrent_build(StoreRoot, Temp, Specs) ->
    Target = filename:join(Temp, "site-concurrent-winner"),
    Parent = self(),
    Ref = make_ref(),
    Deadline = site_build_deadline(),
    Workers = [spawn_monitor(
                 fun() -> site_build_worker(Parent, Ref, StoreRoot, Specs,
                                            Target, Deadline)
                 end) || _ <- [1, 2]],
    try
        site_wait_build_ready(Workers, Ref, Deadline, #{}),
        [Pid ! {site_build_go, Ref} || {Pid, _Monitor} <- Workers],
        Results = site_wait_build_completion(Workers, Ref, Deadline, #{}, #{}),
        Successes = [Index || {_Pid, {ok, Index}} <- Results],
        Losers = [Reason || {_Pid, {error, Reason}} <- Results],
        ?assertEqual(1, length(Successes)),
        ?assertEqual([output_exists], Losers),
        ?assertEqual(unicode:characters_to_binary(
                       filename:join(Target, "index.html")), hd(Successes)),
        ?assertEqual(16, length(site_tree_snapshot(Target)))
    after
        cancel_monitored(Workers)
    end,
    site_worker_failure_cleanup_probe(),
    ok.

site_build_deadline() ->
    erlang:monotonic_time(millisecond) + 30000.

site_build_remaining(Deadline) ->
    case Deadline - erlang:monotonic_time(millisecond) of
        Remaining when Remaining > 0 -> Remaining;
        _ -> erlang:error(site_build_deadline_exceeded)
    end.

site_build_worker(Parent, Ref, StoreRoot, Specs, Target, Deadline) ->
    Parent ! {site_build_ready, Ref, self()},
    receive
        {site_build_go, Ref} ->
            Result = 'ldoc-site':build(StoreRoot, Specs, Target),
            Parent ! {site_build_result, Ref, self(), Result}
    after site_build_remaining(Deadline) ->
        erlang:error(site_build_worker_gate_deadline_exceeded)
    end.

site_wait_build_ready(Workers, Ref, Deadline, Ready) ->
    case map_size(Ready) =:= length(Workers) of
        true -> ok;
        false ->
            receive
                {site_build_ready, Ref, Pid} ->
                    case {site_expected_worker(Pid, Workers),
                          maps:is_key(Pid, Ready)} of
                        {true, false} ->
                            site_wait_build_ready(
                              Workers, Ref, Deadline,
                              maps:put(Pid, true, Ready));
                        _ -> erlang:error(site_build_unexpected_ready)
                    end;
                {'DOWN', Monitor, process, Pid, Reason} ->
                    case site_expected_monitor(Pid, Monitor, Workers) of
                        true -> erlang:error({site_build_worker_before_ready,
                                              Pid, Reason});
                        false -> site_wait_build_ready(
                                   Workers, Ref, Deadline, Ready)
                    end
            after site_build_remaining(Deadline) ->
                erlang:error(site_build_deadline_exceeded)
            end
    end.

site_wait_build_completion(Workers, Ref, Deadline, Results, Downs) ->
    Count = length(Workers),
    case map_size(Results) =:= Count andalso map_size(Downs) =:= Count of
        true -> maps:to_list(Results);
        false ->
            receive
                {site_build_result, Ref, Pid, Result} ->
                    case {site_expected_worker(Pid, Workers),
                          maps:is_key(Pid, Results)} of
                        {true, false} ->
                            site_wait_build_completion(
                              Workers, Ref, Deadline,
                              maps:put(Pid, Result, Results), Downs);
                        _ -> erlang:error(site_build_unexpected_result)
                    end;
                {'DOWN', Monitor, process, Pid, normal} ->
                    case {site_expected_monitor(Pid, Monitor, Workers),
                          maps:is_key(Pid, Downs),
                          maps:is_key(Pid, Results)} of
                        {true, false, true} ->
                            site_wait_build_completion(
                              Workers, Ref, Deadline, Results,
                              maps:put(Pid, normal, Downs));
                        {true, false, false} ->
                            erlang:error({site_build_worker_missing_result,
                                          Pid});
                        _ -> site_wait_build_completion(
                               Workers, Ref, Deadline, Results, Downs)
                    end;
                {'DOWN', Monitor, process, Pid, Reason} ->
                    case site_expected_monitor(Pid, Monitor, Workers) of
                        true -> erlang:error({site_build_worker_crashed,
                                              Pid, Reason});
                        false -> site_wait_build_completion(
                                   Workers, Ref, Deadline, Results, Downs)
                    end
            after site_build_remaining(Deadline) ->
                erlang:error(site_build_deadline_exceeded)
            end
    end.

site_expected_worker(Pid, Workers) ->
    lists:keymember(Pid, 1, Workers).

site_expected_monitor(Pid, Monitor, Workers) ->
    lists:keyfind(Pid, 1, Workers) =:= {Pid, Monitor}.

site_worker_failure_cleanup_probe() ->
    Ref = make_ref(),
    Deadline = site_build_deadline(),
    FailureWorker = spawn_monitor(
                      fun() ->
                          receive
                              {site_probe_crash, Ref} ->
                                  exit(site_probe_expected_crash)
                          after site_build_remaining(Deadline) ->
                              erlang:error(site_probe_deadline_exceeded)
                          end
                      end),
    Survivor = spawn_monitor(
                 fun() ->
                     receive
                         {site_probe_release, Ref} -> ok
                     after site_build_remaining(Deadline) ->
                         erlang:error(site_probe_deadline_exceeded)
                     end
                 end),
    FailurePid = element(1, FailureWorker),
    SurvivorPid = element(1, Survivor),
    Workers = [FailureWorker, Survivor],
    try
        FailurePid ! {site_probe_crash, Ref},
        Observed = try
                       site_wait_build_completion(
                         Workers, Ref, Deadline, #{}, #{})
                   of
                       Result -> {unexpected_completion, Result}
                   catch
                       error:Reason -> {error, Reason}
                   after
                       cancel_monitored(Workers)
                   end,
        ?assertEqual({error, {site_build_worker_crashed,
                              FailurePid, site_probe_expected_crash}},
                     Observed),
        site_assert_worker_stopped(SurvivorPid, Deadline),
        ?assertNot(is_process_alive(FailurePid)),
        ok
    after
        cancel_monitored(Workers)
    end.

site_assert_worker_stopped(Pid, Deadline) ->
    Monitor = erlang:monitor(process, Pid),
    receive
        {'DOWN', Monitor, process, Pid, _Reason} -> ok
    after site_build_remaining(Deadline) ->
        _ = erlang:demonitor(Monitor, [flush]),
        erlang:error(site_build_worker_cleanup_deadline_exceeded)
    end.

site_release_route(Release) ->
    Namespace = maps:get(namespace, Release),
    Package = maps:get(package, Release),
    Version = maps:get(version, Release),
    Preimage = <<(byte_size(Namespace)):32/unsigned-big, Namespace/binary,
                 (byte_size(Package)):32/unsigned-big, Package/binary,
                 (byte_size(Version)):32/unsigned-big, Version/binary>>,
    Hex = binary:encode_hex(crypto:hash(sha256, Preimage), uppercase),
    <<"r-", Hex/binary>>.

has_binary_prefix(Binary, Prefix) ->
    byte_size(Binary) >= byte_size(Prefix) andalso
    binary:part(Binary, 0, byte_size(Prefix)) =:= Prefix.

site_tree_snapshot(Root) ->
    lists:sort(site_tree_entries(Root, "", [])).

site_tree_entries(Root, Relative, Acc) ->
    Current = case Relative of
                  "" -> Root;
                  _ -> filename:join(Root, Relative)
              end,
    {ok, Names} = file:list_dir(Current),
    lists:foldl(
      fun(Name, Items) ->
          Rel = case Relative of
                    "" -> Name;
                    _ -> filename:join(Relative, Name)
                end,
          Path = filename:join(Root, Rel),
          case filelib:is_dir(Path) of
              true -> site_tree_entries(Root, Rel, Items);
              false ->
                  {ok, Bytes} = file:read_file(Path),
                  [{unicode:characters_to_binary(Rel), Bytes} | Items]
          end
      end, Acc, Names).

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
    ModernShow = view_definition(Sourced, <<"erlang">>, <<"ldoc_modern">>,
                                 <<"function">>, <<"show">>, 1),
    case native_modern_source_state(Docset, Root) of
        absent ->
            ?assertNot(maps:is_key(source, Modern)),
            ?assertNot(maps:is_key(source, ModernShow));
        present ->
            ?assertEqual(#{path => <<"ldoc_modern.erl">>, line => 1},
                         maps:get(source, Modern)),
            ?assertEqual(#{path => <<"ldoc_modern.erl">>, line => 14},
                         maps:get(source, ModernShow))
    end,
    analysis_native_source_classifier_negative(Root, Docset),
    analysis_authored_source_fixture(Root, Docset),
    Classic = view_module(Sourced, <<"erlang">>, <<"ldoc_classic">>),
    ?assertEqual(#{path => <<"ldoc_classic.erl">>, line => 2},
                 maps:get(source, Classic)),
    ClassicShow = view_definition(Sourced, <<"erlang">>,
                                  <<"ldoc_classic">>, <<"function">>,
                                  <<"show">>, 1),
    ?assertEqual(#{path => <<"ldoc_classic.erl">>, line => 7},
                 maps:get(source, ClassicShow)),
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
    NullListFilename = binary_to_list(NullFilename),
    NullListDocset = map_entry(
                       fun(Entry) ->
                           Entry#{metadata := #{source_anno =>
                               erl_anno:set_file(NullListFilename,
                                                 erl_anno:new(37))}}
                       end,
                       update_module(
                         fun(Module) ->
                             Module#{metadata :=
                                         #{source_path => NullListFilename},
                                     source := malformed}
                         end, Docset, <<"ldoc-fixture">>),
                       <<"ldoc-fixture">>, <<"function">>,
                       <<"sample">>, 1),
    {ok, NullListView} = 'ldoc-analysis':view(
                           NullListDocset, #{source_root => Root}),
    NullListModule = view_module(NullListView, <<"lfe">>,
                                 <<"ldoc-fixture">>),
    ?assertNot(maps:is_key(source, NullListModule)),
    NullListDefinition = view_definition(NullListView, <<"lfe">>,
                                        <<"ldoc-fixture">>,
                                        <<"function">>, <<"sample">>, 1),
    ?assertNot(maps:is_key(source, NullListDefinition)),
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

native_modern_source_state(Docset, Root) ->
    NativeModern = module_named(maps:get(modules, Docset),
                                <<"ldoc_modern">>),
    NativeModernMetadata = maps:get(metadata, NativeModern),
    NativeModernShow = entry(maps:get(entries, NativeModern),
                             <<"function">>, <<"show">>, 1),
    NativeModernShowMetadata = maps:get(metadata, NativeModernShow),
    ExpectedModernPath = filename:join(Root, "ldoc_modern.erl"),
    case {NativeModernMetadata, NativeModernShowMetadata} of
        {#{otp_doc_vsn := {1, 0, 0}}, #{}}
          when NativeModernMetadata =:= #{otp_doc_vsn => {1, 0, 0}},
               NativeModernShowMetadata =:= #{} ->
            absent;
        {#{otp_doc_vsn := {1, 0, 0}, behaviours := [],
           source_anno := {1, 2}, source_path := ExpectedModernPath},
         #{source_anno := {14, 1}}}
          when NativeModernMetadata =:=
                 #{otp_doc_vsn => {1, 0, 0}, behaviours => [],
                   source_anno => {1, 2},
                   source_path => ExpectedModernPath},
               NativeModernShowMetadata =:= #{source_anno => {14, 1}} ->
            present;
        OtherNativeSourceMetadata ->
            erlang:error({unexpected_modern_source_metadata,
                          OtherNativeSourceMetadata})
    end.

analysis_native_source_classifier_negative(Root, Docset) ->
    MissingSourceModule = update_module(
                            fun(Module) ->
                                Module#{metadata :=
                                            #{otp_doc_vsn => {1, 0, 0}}}
                            end, Docset, <<"ldoc_modern">>),
    UnexpectedShowMetadata = #{unexpected_native_source_metadata => true},
    UnexpectedShow = map_entry(
                       fun(Entry) ->
                           Entry#{metadata := UnexpectedShowMetadata}
                       end, MissingSourceModule, <<"ldoc_modern">>,
                       <<"function">>, <<"show">>, 1),
    Observed = try native_modern_source_state(UnexpectedShow, Root) of
                   State -> {returned, State}
               catch
                   error:Reason -> {raised, Reason}
               end,
    ?assertEqual(
       {raised,
        {unexpected_modern_source_metadata,
         {#{otp_doc_vsn => {1, 0, 0}}, UnexpectedShowMetadata}}},
       Observed).

assert_native_modern_source_html(Html, Docset, Root, SourceBase) ->
    case native_modern_source_state(Docset, Root) of
        absent ->
            ?assertEqual(nomatch, binary:match(Html, <<"class=\"source\"">>));
        present ->
            ?assert(binary:match(
                      Html, <<SourceBase/binary,
                              "ldoc_modern.erl#L1">>) =/= nomatch),
            ?assert(binary:match(
                      Html, <<SourceBase/binary,
                              "ldoc_modern.erl#L14">>) =/= nomatch)
    end.

analysis_authored_source_fixture(Root, Docset) ->
    ModulePath = filename:join([Root, "src", "ldoc_modern.erl"]),
    ModuleSourceAnno = erl_anno:set_file(ModulePath, erl_anno:new(1)),
    ShowSourceAnno = erl_anno:set_file(ModulePath, erl_anno:new(14)),
    ModuleDocset = update_module(
                     fun(Module) ->
                         Module#{metadata := #{source_path => ModulePath,
                                               source_anno =>
                                                   ModuleSourceAnno}}
                     end, Docset, <<"ldoc_modern">>),
    AuthoredSourceDocset = map_entry(
                             fun(Entry) ->
                                 Entry#{metadata :=
                                            #{source_anno => ShowSourceAnno}}
                             end, ModuleDocset, <<"ldoc_modern">>,
                             <<"function">>, <<"show">>, 1),
    ?assertNotEqual(Docset, AuthoredSourceDocset),
    {ok, AuthoredView} = 'ldoc-analysis':view(
                           AuthoredSourceDocset,
                           #{source_root => Root}),
    AuthoredModule = view_module(AuthoredView, <<"erlang">>,
                                 <<"ldoc_modern">>),
    ?assertEqual(#{path => <<"src/ldoc_modern.erl">>, line => 1},
                 maps:get(source, AuthoredModule)),
    AuthoredShow = view_definition(AuthoredView, <<"erlang">>,
                                  <<"ldoc_modern">>, <<"function">>,
                                  <<"show">>, 1),
    ?assertEqual(#{path => <<"src/ldoc_modern.erl">>, line => 14},
                 maps:get(source, AuthoredShow)).

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
