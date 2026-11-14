# ldoc 0.1.1 overview

This source builds ldoc 0.1.1, a source-based tool that collects native
documentation from trusted Erlang and LFE BEAM files, stores a readable
snapshot, selects a presentation view, and renders a local static HTML
reference. The output is useful offline and does not require a hosted service.

## Build a project reference

Configure ldoc as a development-only project plugin, then run `rebar3 ldoc` in
an ordinary flat Erlang or LFE project:

```sh
{project_plugins, [{ldoc, "0.1.1"}]}.
```

The stable index is `_build/default/ldoc/current/site/index.html`. Successful
generations are retained and `current` switches only after a successful build.
The plugin output is separate from maintainer docs under `_build/ldoc/docs.*`.
After Rebar is killed, inspect `.ldoc-lock` and confirm no build remains active
before removing a stale lock. The filesystem must support relative symlinks.
Only the default profile is supported. LFE projects still configure the LFE
runtime dependency and compiler plugin in their normal `deps` and `plugins`.

For a separate destination, choose a fresh output root:

```sh
rebar3 ldoc --output "$PWD/reference"
```

The exact version shown in a generated reference comes from the compiled
application resource. Source links are opt-in with `--source-root` and
`--source-base`; ldoc does not infer a repository host, revision, or checkout.

The command supports a flat default-profile application with one root
`src/*.app.src` and direct nonempty `src/*.erl` and `src/*.lfe` files. It checks
the source module list against the compiled application and BEAM inventory.
Umbrella, nested, custom-layout, and non-default-profile builds are outside this
command's supported shape. Installed command, prefix, and output paths support
spaces and Unicode with UTF-8 native filename encoding. A project root used for
a cold dependency build is subject to LFE 2.2.2's `app_compile` hook, which
constructs a command with an unquoted path; use a space-free source/cache/build
root for that cold build.

## Prepare maintainer docs and packages

From the checkout, `make docs` builds a fresh reference using the compiled
application version and retains it under
`_build/ldoc/docs.XXXXXXXX/reference/site`. `DOCS_PARENT` can select another
persistent parent, and `DOCGEN` can select a built ldoc executable.

```sh
make check
make docs
make publish PUBLISH_FLAGS="--dry-run --yes"
```

`make publish` builds a new reference in unique temporary staging and invokes
the official combined source-and-docs Hex provider once. The staging tree is
removed on exit while `make docs` output stays available. The dry-run builds
both payloads without uploading either package. A real publish needs the maintainer's normal
Hex authorization. The official source package can be written for inspection
with `rebar3 hex build package`. Its default output is
`_build/default/lib/ldoc/hex/ldoc-0.1.1.tar` after the application is built.
The package metadata and file list identify the source release, while the
generated site supplies its docs package. No prebuilt executable is produced by these commands.

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
