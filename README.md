# LDOC

LDOC collects API documentation for Erlang, modern LFE, and classic LFE from trusted local BEAM artifacts. `collect/1` looks for an embedded EEP-48 `Docs` chunk, then an associated package sidecar, then the classic LFE `LDoc` chunk in the same BEAM. It falls back only when a source is absent.

`read-docs/1` reads embedded EEP-48 `Docs` only. Both readers return the same module map shape and work from the supplied artifact without loading the target module or searching the code path.

```erlang
'ldoc-beam':'read-docs'("_build/default/lib/my_app/ebin/my_module.beam").
'ldoc-beam':collect("_build/default/lib/my_app/ebin/my_module.beam").
```

## Store exact release snapshots

Assemble the complete native docset, then save and retrieve it by the exact
release key. The store writes a readable, versioned LFE data form under a
bounded SHA-256 filename; it does not infer aliases or order versions.

```erlang
Release = #{namespace => <<"local">>, package => <<"my_app">>,
            version => <<"1.2.0">>},
Inputs = ["_build/default/lib/my_app/ebin/my_module.beam"],
{ok, Docset} = 'ldoc-docset':assemble(Release, Inputs),
ok = 'ldoc-store':put("/var/tmp/ldoc-snapshots", Docset),
{ok, Docset} = 'ldoc-store':get("/var/tmp/ldoc-snapshots", Release).
```

An identical retry returns `ok` without rewriting the snapshot. A different
docset under the same exact release key returns
`{error, {release_conflict, Release}}`, leaving the existing release data
unchanged. Different version keys coexist and remain independently
retrievable. Snapshots retain their complete producer maps as native LFE
terms, including metadata, provenance and structured documentation.

The caller chooses a trusted local store directory on a filesystem that
supports exclusive file creation and same-directory hard links. The hard-link
insertion is the immutable publication point. This protects concurrent writers
and process interruption on a live filesystem; power-loss durability depends
on additional guarantees from the filesystem and operating system.

The readable data subset follows LFE's stock literal writers: comments and
whitespace, direct literal binary strings, byte values, and an optional final
partial-byte size segment are supported. Reader-eval forms (`#.`) and computed
binary expressions are invalid snapshots. Maps containing the LFE struct
marker key `__struct__` are retained as ordinary data using LFE's plain
readable printer because the pretty-printer treats that key as struct syntax.

## Build a native analysis view

Retrieve the exact release, then project it through `ldoc-analysis:view/1`.
The view groups languages, modules and candidate definitions while retaining
the binary kind/name/arity identity and selected documentation as native
terms. Overloads remain separate, and a classic macro keeps `unknown` arity.

```erlang
{ok, Docset} = 'ldoc-store':get(StoreRoot, Release),
{ok, View} = 'ldoc-analysis':view(Docset).
```

The projection is a selected presentation boundary. It copies module name,
format and documentation; definition kind, name, arity, signatures,
documentation and producer patterns when present; plus optional relative
source references. It excludes internal entries and suppresses definitions
for hidden modules. Candidate entries with hidden documentation remain
visible with that state. Structured EDoc bodies, signatures and classic
patterns stay in native form. Opaque metadata, raw spec terms, annotations,
carrier paths and arbitrary source data stay in the stored docset.

Source references are absent by default. To include them, supply a declared
absolute source root with `view/2`:

```erlang
{ok, ViewWithSources} =
    'ldoc-analysis':view(Docset, #{source_root => SourceRoot}).
```

Only recorded source-file provenance beneath that root can produce a
relative path and a known positive line. This is lexical projection: it does
not inspect the filesystem, resolve symlinks, verify file existence, or
authenticate the caller's declaration. It never infers a source from a BEAM
or sidecar path, and it leaves path-like prose unchanged. Arc 03 can define
target links from these relative references.

An LFE consumer can traverse the native view without reading collector or
store internals:

```erlang
DefinitionIndex = maps:from_list([
    {{Language, maps:get(name, Module), maps:get(kind, Definition),
      maps:get(name, Definition), maps:get(arity, Definition)}, Definition}
    || #{name := Language, modules := Modules} <- maps:get(languages, View),
       Module <- Modules,
       Definition <- maps:get(definitions, Module)]).
```

The store retains the complete producer record, including raw specs and
annotations. This view exposes the producer's existing signature binaries;
typed-spec presentation and JSON or other wire formats need a later,
consumer-specific contract.

## Generate an EEP-48 sidecar with EDoc

For a source-comment module, compile and run OTP EDoc as a caller step. Use a fresh trusted package or output directory so an old chunk cannot be mistaken for the current conversion. The package layout is `ebin/<module>.beam` beside `doc/chunks/<module>.chunk`.

```erlang
{ok, Module, Beam} =
    compile:file(SourcePath, [binary, {i, IncludeDir}]),
BeamPath = filename:join(PackageEbinDir, atom_to_list(Module) ++ ".beam"),
ok = filelib:ensure_dir(BeamPath),
ok = file:write_file(BeamPath, Beam),
ok = filelib:ensure_dir(filename:join(PackageDocDir, "chunks/placeholder")),
ok = edoc:files([SourcePath],
                [{dir, PackageDocDir},
                 {doclet, edoc_doclet_chunks},
                 {layout, edoc_layout_chunks},
                 {preprocess, true},
                 {includes, [IncludeDir]}]).
```

Then collect the package BEAM. The second form records the caller's source and include declaration with the sidecar result; it does not run EDoc or verify those paths.

```erlang
'ldoc-beam':collect(BeamPath).
'ldoc-beam':collect(BeamPath, {edoc, SourcePath, [IncludeDir]}).
```

The declaration is preserved as `conversion => #{tool => edoc, source_path => SourcePath, include_paths => IncludeDirs, evidence => caller_declared}` only when a sidecar is selected. Embedded results keep their original source map. A nonempty string or binary source path and a proper list of nonempty string or binary include paths are required; the include list may be empty.

## Collect classic LFE documentation

`collect/1` also reads the versioned `LDoc` chunk emitted by LFE 1.2.0, after embedded EEP-48 `Docs` and an eligible same-package sidecar are absent. The legacy record is decoded from the bytes read from the supplied BEAM; the module is not loaded. `read-docs/1` remains an embedded `Docs`-only operation and returns `missing_docs` for a classic-only artifact.

The result uses the shared module and entry maps. Its source is `#{carrier => embedded_beam, path => Path, chunk => <<"LDoc">>, legacy_version => lfe_docs_v1, format_policy => lodox_markdown}`. The producer did not record a module annotation or a documentation locale, so the module annotation is `undefined` and nonempty docs use `#{<<"und">> => Text}`. The text joins the original binary lines with newlines; the exact source lines remain in `metadata.legacy_doc_lines`. Entry `patterns` retain the original function and macro terms, including guarded clauses. The entry metadata retains `legacy_doc_lines` and `legacy_exported`; function lines become annotations and signatures are empty. Legacy macro arity is `unknown`, even if a clause looks fixed-arity. Empty producer doc lists remain `none`. Lodox interpreted these docstrings as Markdown.

The selection order is embedded `Docs`, an associated sidecar under the immediate package root, then `LDoc` from the same BEAM bytes. Only an exact `missing_docs` result from sidecar selection advances to `LDoc`; present invalid Docs, sidecar read failures, and rejected sidecar associations stay errors. A missing `LDoc` chunk returns `missing_docs`; a malformed or unsupported versioned payload returns `invalid_ldoc`. The `LDoc` adapter preserves producer patterns as data and does not execute them.

### Reproduce the classic fixture

The shipped `test/fixtures/ldoc-legacy.beam.fixture` is a genuine compiler output for `test/fixtures/ldoc-legacy.lfe.fixture`. Regeneration needs the pinned local LFE repository and an OTP 19.3 installation. Set `LFE_REPO` to a clone containing commit `a4b20a050d38e3f494cdf4a1a99adbe11e7b6ced` and `OTP19_BIN` to the OTP 19.3 `bin` directory:

```sh
LFE_REPO=/path/to/lfe
OTP19_BIN=/path/to/otp-19.3/bin
WORK=$(mktemp -d)
mkdir -p "$WORK/lfe" "$WORK/source"
git -C "$LFE_REPO" archive --format=tar a4b20a050d38e3f494cdf4a1a99adbe11e7b6ced | tar -xf - -C "$WORK/lfe"
cp test/fixtures/ldoc-legacy.lfe.fixture "$WORK/source/ldoc-legacy.lfe"
(cd "$WORK/lfe" && PATH="$OTP19_BIN:$PATH" ERL_FLAGS='+S 2:2' make)
(cd "$WORK/source" && PATH="$OTP19_BIN:$PATH" ERL_FLAGS='+S 2:2' "$OTP19_BIN/erl" -noshell -pa "$WORK/lfe/ebin" -eval '
    Source = "ldoc-legacy.lfe",
    {ok, [{ok, Module, Beam}]} = lfe_comp:file(Source, [binary, report]),
    true = (atom_to_list(Module) =:= "ldoc-legacy"),
    ok = file:write_file("ldoc-legacy.beam", Beam),
    {ok, {Module, [{"LDoc", Chunk}]}} = beam_lib:chunks(Beam, ["LDoc"]),
    ok = file:write_file("ldoc-legacy.ldoc", Chunk),
    halt().')
shasum -a 256 "$WORK/source/ldoc-legacy.ldoc"
```

The expected raw LDoc chunk is 555 bytes with SHA-256 `a4191d04427134e4ffb4e28011f1b97dcff754609b394e6e23e801c1fb2a8ea6`. Compare those extracted bytes with a separately extracted chunk from the shipped BEAM fixture. The full BEAM may differ because compiler metadata records the source path.

For sidecars, LDOC uses the module identity read from the supplied BEAM and checks only the immediate package root above its `ebin` directory. It does not infer identity from the filename, walk ancestors, or consult the VM code path. Embedded docs are authoritative, including `hidden` and `none`; only a missing embedded chunk advances to the sidecar. A malformed embedded chunk remains `invalid_docs` even if a sidecar exists.

Filesystem errors retain tagged reasons (`read_beam` or `read_sidecar`). Invalid BEAMs, missing docs, invalid docs, invalid package associations, and invalid EDoc provenance have distinct tagged errors. Sidecars contain no module/build identity to authenticate their contents, so collection assumes a trusted package with stable contents. Do not use this reader for hostile or public artifacts; atom creation and resource bounds need a separate isolation design.
