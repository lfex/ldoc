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

For sidecars, LDOC uses the module identity read from the supplied BEAM and checks only the immediate package root above its `ebin` directory. It does not infer identity from the filename, walk ancestors, or consult the VM code path. Embedded docs are authoritative, including `hidden` and `none`; only a missing embedded chunk advances to the sidecar. A malformed embedded chunk remains `invalid_docs` even if a sidecar exists.

Filesystem errors retain tagged reasons (`read_beam` or `read_sidecar`). Invalid BEAMs, missing docs, invalid docs, invalid package associations, and invalid EDoc provenance have distinct tagged errors. Sidecars contain no module/build identity to authenticate their contents, so collection assumes a trusted package with stable contents. Do not use this reader for hostile or public artifacts; atom creation and resource bounds need a separate isolation design.
