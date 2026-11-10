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
    eep_s05(Temp, LfeSource, LfeBeam).

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

entry_keys(Entries) ->
    [{maps:get(kind, E), maps:get(name, E), maps:get(arity, E)} || E <- Entries].

assert_entry(Entries, Kind, Name, Arity, Line, Signatures, Doc, Visibility) ->
    Entry = entry(Entries, Kind, Name, Arity),
    ?assertEqual(Line, erl_anno:line(maps:get(annotation, Entry))),
    ?assertEqual(Signatures, maps:get(signatures, Entry)),
    ?assertEqual(Doc, maps:get(doc, Entry)),
    ?assertEqual(Visibility, maps:get(visibility, Entry)),
    ?assert(is_map(maps:get(metadata, Entry))).

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
    {ok, _, Chunks} = beam_lib:all_chunks(Beam),
    WithoutDocs = [Chunk || Chunk = {Name, _} <- Chunks, Name =/= "Docs"],
    {ok, NewBeam} = beam_lib:build_module([{"Docs", DocsBytes} | WithoutDocs]),
    NewBeam.

remove_chunk(Beam, Name) ->
    {ok, _, Chunks} = beam_lib:all_chunks(Beam),
    {ok, NewBeam} = beam_lib:build_module(
                      [Chunk || Chunk = {ChunkName, _} <- Chunks,
                                ChunkName =/= Name]),
    NewBeam.
