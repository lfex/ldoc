# ldoc overview

`ldoc` builds a local, static reference for a trusted flat Erlang or LFE
application. It collects native documentation from compiled BEAM files, stores
a readable snapshot, selects a presentation view, and renders a local HTML
bundle. The output is useful offline and does not require a hosted service.

## Build a project reference

Use a fresh output root whose parent already exists. The exact version shown in
the reference is read from the compiled application resource; the output folder
name is only your label.

```sh
ldoc build "$PWD" --output "$PWD/reference-1.2.0" \
  --overview "$PWD/docs/overview.md" \
  --source-root "$PWD" \
  --source-base "https://example.test/my-app/"
```

Open `reference-1.2.0/site/index.html`. The source root and source base are
explicit declarations. A source link is emitted only when selected documentation
contains a real source record beneath that root; ldoc does not infer or verify
a repository host, revision, or checkout. Choose another new output directory
for each build because existing targets are never replaced.

The command supports a flat default-profile application with one root
`src/*.app.src` and direct nonempty `src/*.erl` and `src/*.lfe` files. It checks
the source module list against the compiled application and BEAM inventory.
Umbrella, nested, custom-layout, and non-default-profile builds are outside this
command's supported shape. Installed command, prefix, and output paths support
spaces and Unicode with UTF-8 native filename encoding. A project root used for
a cold dependency build is subject to LFE 2.2.2's `app_compile` hook, which
constructs a command with an unquoted path; use a space-free source/cache/build
root for that cold build.

## Use the library pipeline

The public APIs separate artifact reading, complete release assembly, snapshot
storage, analysis selection, and HTML rendering. The caller chooses the exact
release key and the BEAM paths to collect.

```erlang
Release = #{namespace => <<"local">>, package => <<"my_app">>,
            version => <<"1.2.0">>},
Inputs = ["_build/default/lib/my_app/ebin/my_module.beam"],
{ok, Docset} = 'ldoc-docset':assemble(Release, Inputs),
ok = 'ldoc-store':put("/var/tmp/my_app-snapshots", Docset),
{ok, Stored} = 'ldoc-store':get("/var/tmp/my_app-snapshots", Release),
{ok, View} = 'ldoc-analysis':view(Stored),
{ok, Files} = 'ldoc-html':render(View, #{overview => <<"# My API">>}).
```

`Files` is a sorted list of relative filenames and UTF-8 byte binaries. The
renderer does not write these files; the caller decides where to save them.
For multiple exact releases, `ldoc-site:build/3,4` composes stored releases into
a new catalogue and versioned directory tree.

## Documentation and trusted inputs

The reader accepts a trusted BEAM path. It reads embedded EEP-48 Docs first,
then an associated immediate-package sidecar, then classic LFE LDoc in the
same BEAM, and falls back only when a carrier is absent. A malformed present
carrier is an error. The tool VM inspects BEAM data without loading target
modules. A CLI build starts a trusted child Rebar process; project scripts,
hooks, and compile-time code may run during compilation.

For Erlang source documentation, EDoc generation is a caller or CLI build step.
The `ldoc-beam:collect/2` EDoc provenance value records a caller declaration
when a sidecar is selected; it does not run EDoc or authenticate the source
paths. Modern LFE producers can embed Docs directly, while classic LFE records
are normalized without executing stored patterns.

Snapshots retain complete producer metadata, annotations, structured bodies,
and raw specs when those terms fit the supported readable literal subset. The
analysis view selects native signatures and patterns; it does not format raw
typed specs as inferred types. HTML supports a documented Markdown subset and
validated structured EDoc nodes, escapes raw HTML, and does not fetch remote
content. The shell and generated interface are English and left-to-right; no
paragraph-level bidirectional policy is implied by Unicode text support.
