# LDOC

LDOC collects EEP-48 documentation from trusted local BEAM artifacts. `read-docs/1` reads only an embedded `Docs` chunk. `collect/1` prefers embedded docs and falls back, only when the chunk is absent, to the EEP-48 sidecar associated with that BEAM's package. Both return the same normalized module map; neither loads the target module or searches the code path.

```erlang
'ldoc-beam':'read-docs'("_build/default/lib/my_app/ebin/my_module.beam").
'ldoc-beam':collect("_build/default/lib/my_app/ebin/my_module.beam").
```

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
