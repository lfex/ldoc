# ldoc

This source builds ldoc 0.1.1, which collects API documentation for Erlang,
modern LFE, and classic LFE from trusted local BEAM artifacts. It assembles
native snapshots and renders a static HTML reference. `collect/1` prefers
embedded EEP-48 Docs, then an associated package sidecar, then classic LFE
LDoc from the same BEAM. It falls back only when a carrier is absent.
`read-docs/1` reads embedded Docs only. Neither reader loads the target module
or searches the code path.

## Build a project reference with Rebar3

For an ordinary Erlang project, add ldoc as a development-only plugin in
`rebar.config`:

```erlang
{project_plugins, [{ldoc, "0.1.1"}]}.
```

For an LFE project, keep its normal runtime and compiler configuration and add
ldoc only to `project_plugins`:

```erlang
{deps, [{lfe, "2.2.2"}]}.
{plugins, [{rebar3_lfe, "0.5.8"}]}.
{project_plugins, [{ldoc, "0.1.1"}]}.
```

Run `rebar3 ldoc`, then open `_build/default/ldoc/current/site/index.html`.
The plugin builds the default
profile and leaves the application's normal compiler settings intact. Rebar3
3.28.0 is the verified provider version. Erlang source-comment conversion
requires OTP's `edoc_doclet_chunks` and `edoc_layout_chunks` tools. Use
`rebar3 help ldoc` for provider options. ldoc is development-only and does not
become a runtime dependency of the documented application.

### Advanced output behavior

Each successful run retains its private generation and atomically changes
`current`. This container is separate from maintainer output under
`_build/ldoc/docs.*`. If Rebar is killed, inspect `.ldoc-lock` and confirm no
build remains active before removing a stale lock. The filesystem must support
relative symlinks. Non-default profiles are rejected because child default
compilation does not inherit a parent's compiled profile inventory.

Pass `--output PATH` to select a different destination; it must be fresh and is
never replaced or deleted:

```sh
rebar3 ldoc --output /absolute/path/to/reference
```

### Install the standalone command from a source checkout

For development, install the current checkout directly. `make check` is a
separate optional compile-and-test gate, not a prerequisite hidden in the
install recipe.

```sh
make install PREFIX="$HOME/.local"
"$HOME/.local/bin/ldoc" --help
```

### Maintainer package and docs checks

From a source checkout, the maintained reference and combined Hex provider
flow are:

```sh
make check
make docs
make publish PUBLISH_FLAGS="--dry-run --yes"
```

`make docs` builds a fresh versioned reference under
`_build/ldoc/docs.XXXXXXXX/reference/site` and leaves it available for browsing.
Set `DOCS_PARENT` to choose another persistent parent, or `DOCGEN` to select a
built ldoc executable. The release version comes from the compiled app resource.
`make publish` builds a separate fresh reference under a unique `publish.*`
staging directory and calls the combined source-and-docs Hex publish provider
once. Its EXIT trap removes only that staging directory; persistent `make docs`
outputs remain. `--dry-run --yes` builds both provider payloads without
uploading either package. A real publish requires the maintainer's normal
Hex authorization.

To inspect the official source package separately, run
`rebar3 hex build package`. The default output is
`_build/default/lib/ldoc/hex/ldoc-0.1.1.tar` after the application is built.
The package contains the application source, tests, README, overview, LICENSE,
Makefile, and Rebar configuration/lock. The companion docs package is generated
from the same versioned site used by the combined provider. These source/docs
artifacts describe the release; ldoc does not provide a prebuilt executable
through this workflow.

### Build a local reference

From a trusted flat single-application checkout, run:

```sh
"$HOME/.local/bin/ldoc" build "$PWD" \
  --output "$PWD/ldoc-1.2.0" \
  --overview "$PWD/README.md" \
  --source-root "$PWD" \
  --source-base "https://example.test/my-app/"
```

The output root must be new, and its parent directory must already exist.
Open `ldoc-1.2.0/site/index.html`. The `1.2.0` part is a caller-chosen output
directory label; the exact release version in the reference comes from the
compiled application resource. Use another fresh output directory for another
run; ldoc never replaces an existing path. The root retains staged package
BEAMs and the readable native snapshot used for the site. Without `--overview`,
ldoc uses the project's `README.md` when present. The source root and source
base are explicit caller declarations; ldoc does not infer or verify a
repository host or revision.

The command owns the ordinary `rebar3 compile` step and accepts one root
`src/*.app.src` plus nonempty, direct `src/*.erl` and `src/*.lfe` module files
under the default `_build/default/lib/APP/ebin` layout. Umbrella, nested,
custom-layout, and non-default-profile builds are not supported by this
command. It verifies that source modules, the compiled application module
list, and compiled BEAM files agree before claiming the output path.

Embedded Docs chunks remain authoritative. For an Erlang module without one,
the command generates an EDoc chunk in its owned output package from matching
source and available compile-time include and macro context. `collect/2` records
a caller-declared EDoc conversion context only when that sidecar is selected;
it does not run EDoc or authenticate source paths. EDoc generation failures
retain the newly owned partial output for diagnosis; unsupported preprocessing
contexts and unavailable EDoc chunk tools fail visibly.

`ldoc build PROJECT --output FRESH_ROOT --overview FILE --namespace TEXT
--package TEXT --source-root ROOT --source-base URL` lists the optional
arguments. Namespace defaults to `local`; package and exact version default to
the compiled application identity. The installed command path, install prefix,
and generated output paths support spaces and Unicode when native filename
encoding is UTF-8. A project path used
for a cold dependency build is subject to the pinned LFE 2.2.2 dependency's
`app_compile` hook, which constructs a command with an unquoted path; use a
space-free source/cache/build root for that cold build.

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
relative path; a known positive line is included when available. This is
lexical projection: it does
not inspect the filesystem, resolve symlinks, verify file existence, or
authenticate the caller's declaration. It never infers a source from a BEAM
or sidecar path, and it leaves path-like prose unchanged. A rendered source
link requires both a selected relative source record and the caller's explicit
`source_base`; the link does not verify a host, revision, or checkout.

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

## Render a local HTML reference

`ldoc-html:render/1` and `render/2` accept the selected native view from
`ldoc-analysis:view/1` and return `{ok, Files}`. `Files` is a sorted list of
`{RelativeFilenameBinary, UTF8BytesBinary}` entries: `index.html`, one
`m-<SHA-256>.html` module page per module, `ldoc.css`, and `ldoc.js`.
Invalid option maps return `{error, invalid_options}`; malformed or unsupported
views return `{error, invalid_view}`. Rendering is in-memory and does not read
files, load target modules, access the network, or mutate the stored release.

Options are a map containing only:

- `locale`: a nonempty UTF-8 binary, default `<<"en">>`.
- `overview`: UTF-8 Markdown binary for the overview introduction, default
  empty.
- `source_base`: optional absolute HTTP or HTTPS URI ending in `/`, with a
  nonempty host and no userinfo, query, or fragment. An explicit port must be
  0 through 65535. Percent escapes must be complete hexadecimal triplets.
- `version_index`: a boolean, default `false`. When `true`, the exact visible
  version in a release page header links to `../index.html`, the local
  catalogue. This fixed parent link is intended for a release page inside a
  versioned site directory; ordinary single-release exports keep the original
  header by default.

The requested locale still selects documentation by exact key, then `und`,
then the first key in lexical order. A selected body receives an HTML `lang`
attribute only when the key matches ldoc's conservative subset: a two- or
three-letter primary language, optionally followed by a four-letter script
and a two-letter or three-digit region. The primary `und` is never annotated.
Other valid UTF-8 keys still select and render their text without a `lang`
attribute; this subset is not full BCP 47 validation. The generated interface
chrome is English and left-to-right. Preserving Unicode and selecting a
locale do not apply an automatic paragraph-level bidirectional-text policy.

Example: export the returned bundle beneath a caller-selected directory and
open the generated overview. The example's source URL is an explicit caller
declaration, not a value inferred from the store or artifact paths.

```erlang
{ok, Docset} = 'ldoc-store':get(StoreRoot, Release),
{ok, View} = 'ldoc-analysis':view(Docset),
{ok, Files} = 'ldoc-html':render(View,
                                  #{locale => <<"en">>,
                                    overview => <<"# Local API\n\nBrowse the modules below.">>,
                                    source_base => <<"https://example.test/project/">>}),
OutputDir = "/tmp/my_app-reference",
ok = file:make_dir(OutputDir),
ok = lists:foreach(
       fun({Name, Bytes}) ->
           ok = file:write_file(filename:join(OutputDir, binary_to_list(Name)), Bytes)
       end,
       Files).
```

Open `file:///tmp/my_app-reference/index.html` in a browser. For a local HTTP
server, run `python3 -m http.server 8000 --directory /tmp/my_app-reference`
from another terminal and visit `http://localhost:8000/`.

The Markdown renderer implements a safe documented subset: paragraphs, ATX
headings, unordered and decimal ordered lists, blockquotes, fenced code, pipe
tables, inline code, strong/emphasis, and inline links. It is not a full
CommonMark implementation. Raw HTML is shown as escaped text, unsupported
syntax remains text, and images do not fetch remote content. Links are retained
only for validated absolute HTTP, HTTPS, or mailto targets; unsafe and
unsupported targets remain text. `application/erlang+html` documentation uses
an allowlisted walker for nested native EDoc tags and validated link attributes;
unknown tags unwrap safe children, while unsupported nodes are escaped.
Producer HTML attributes such as `id`, `class`, `style`, and event handlers are
not copied into the generated page.

A source action appears only when both the accepted view contains a valid
relative source reference and the caller supplies `source_base`. Each path
component is percent-encoded using unreserved ASCII, slash separators are
preserved, and a known positive line becomes `#L<n>`. No source host, revision,
or target is inferred or verified. This is link construction from declared
inputs, not source checkout authentication. Path-like prose and code are
deliberately retained when they are part of selected documentation; opaque
producer metadata is excluded from the selected HTML view. The renderer does
not promise to scrub or redact documentation text.
Raw typed specs and annotations remain in storage and are not presented as
inferred types by this API; signatures and classic patterns are the selected
native view's documented presentation fields.

## Build a versioned local site

`ldoc-site:build/3` composes exact stored releases through the public store,
analysis-view, and HTML-renderer APIs. Supply a nonempty proper list of
release specifications. Each map has a required exact `release` key and may
include `overview`, `source_root`, and `source_base`. Release keys are not
normalized or semver-sorted; the catalogue groups exact namespace/package
coordinates and lists their exact versions bytewise. The optional fourth
argument accepts only `locale`. Every release is prepared before the builder
claims or changes the output directory.

From the ldoc checkout, start an Erlang shell with `rebar3 shell`; the
compiled application is then available on the code path. Paste the following
block into that shell:

```erlang
{ok, _Started} = application:ensure_all_started(ldoc),
Release1 = #{namespace => <<"local">>, package => <<"site-demo">>,
             version => <<"1.0">>},
Release2 = Release1#{version := <<"2.0">>},
%% This runnable demonstration uses one installed ldoc BEAM for both keys.
%% Real releases should each be assembled from their matching compiled inputs.
Inputs = [code:which('ldoc-docset')],
{ok, Docset1} = 'ldoc-docset':assemble(Release1, Inputs),
{ok, Docset2} = 'ldoc-docset':assemble(Release2, Inputs),
Work = filename:join("/tmp", "ldoc-site-demo-" ++
                     integer_to_list(erlang:system_time(microsecond)) ++ "-" ++
                     integer_to_list(erlang:unique_integer([positive]))),
ok = file:make_dir(Work),
StoreRoot = filename:join(Work, "snapshots"),
ok = file:make_dir(StoreRoot),
ok = 'ldoc-store':put(StoreRoot, Docset1),
ok = 'ldoc-store':put(StoreRoot, Docset2),
Target = filename:join(Work, "site"),
Specs = [#{release => Release1,
           overview => <<"# My application\n\nBrowse the exact API release.">>},
         #{release => Release2}],
{ok, IndexPath} = 'ldoc-site':build(StoreRoot, Specs, Target),
io:format("Open this local index in a browser: ~ts~n", [IndexPath]).
```

The block creates a fresh work directory and snapshots child under `/tmp`,
stores both exact demo releases, and leaves the new `site` target for the
builder to claim. Open the printed absolute `IndexPath` in a browser as a
local file. For HTTP, use the printed index's containing directory in another
terminal, for example `python3 -m http.server 8000 --directory /tmp/ldoc-site-demo-<id>/site`,
then visit `http://localhost:8000/`. The two
demo keys intentionally share the same installed BEAM; for real releases,
pass each release's own matching compiled inputs to `ldoc-docset:assemble/2`.
The catalogue has direct keyboard- and no-script-friendly links to each exact
release. Within a release, each page's visible version link returns to the
catalogue. `source_root` and `source_base` remain caller declarations; a
source link appears only for a relative reference selected by the public
analysis view beneath that root. The builder does not infer a host, revision,
or source target.

The target must not already exist, and its parent must already be a directory.
The caller provides a stable trusted parent; the builder does not resolve
symlinked ancestors or defend a parent another process can replace while the
build runs. A build that loses an exclusive target claim returns
`{error, output_exists}` without changing the winner. Other validation errors
are returned in this order: `invalid_options`, `invalid_store_root`,
`invalid_target`, `invalid_releases`, then `{duplicate_release, Release}`.
After validation, a read/render error is tagged with the exact release and
stage. Parent, directory creation, open, write, and close errors identify the
operation and path. A failed owned build removes its new tree where possible;
cleanup failure is reported with the original operation error. Unexpected
exceptions are re-raised after closing the current descriptor and attempting
owned-tree cleanup.

The generated site is for local browsing after a successful return. It is not
an atomic multi-file publication or a power-loss durability guarantee. An
interrupted process may leave an incomplete owned target for its caller to
inspect and remove. Only generated release routes use bounded SHA-256
identities; no release label becomes a filesystem path. The previous
single-release `ldoc-html:render/1,2` API remains in-memory and keeps its
original header bytes unless its explicit `version_index` option is true.

The independently authored layout takes measured page organization cues from
cljdoc's Reitit 0.11.0 reference and the inspected upstream source at
`74d0cec6bd252321375b68ee3facb8ae8faf3296` (EPL-2.0). ldoc uses no copied
upstream source or assets.

## Generate an EEP-48 sidecar with EDoc

For a source-comment module, compile and run OTP EDoc as a caller step. Use a
fresh trusted package or output directory so an old chunk cannot be mistaken
for the current conversion. The package layout is `ebin/<module>.beam` beside
`doc/chunks/<module>.chunk`.

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

Then collect the package BEAM. The second form records the caller's source and
include declaration with the sidecar result; it does not run EDoc or verify
those paths.

```erlang
'ldoc-beam':collect(BeamPath).
'ldoc-beam':collect(BeamPath, {edoc, SourcePath, [IncludeDir]}).
```

The declaration is preserved as
`conversion => #{tool => edoc, source_path => SourcePath,
                include_paths => IncludeDirs, evidence => caller_declared}`
only when a sidecar is selected. Embedded results keep their original source
map. A nonempty string or binary source path and a proper list of nonempty
string or binary include paths are required; the include list may be empty.

## Collect classic LFE documentation

`collect/1` also reads the versioned `LDoc` chunk emitted by LFE 1.2.0,
after embedded EEP-48 `Docs` and an eligible same-package sidecar are absent.
The legacy record is decoded from bytes read from the supplied BEAM; the module
is not loaded. `read-docs/1` remains an embedded `Docs`-only operation and
returns `missing_docs` for a classic-only artifact.

The result uses the shared module and entry maps. Its source is
`#{carrier => embedded_beam, path => Path, chunk => <<"LDoc">>,
  legacy_version => lfe_docs_v1, format_policy => lodox_markdown}`. The
producer did not record a module annotation or a documentation locale, so the
module annotation is `undefined`; nonempty line lists use
`#{<<"und">> => Text}`. Module and entry line lists are joined with newlines.
Only an empty line list becomes `none`; a nonempty list such as `[<<>>]`
remains an `und` entry with an empty binary body. The exact original lines
remain in `metadata.legacy_doc_lines`. Entry `patterns` retain the original
function and macro terms, including guarded clauses. Entry metadata retains
`legacy_doc_lines` and `legacy_exported`; function lines become annotations
and signatures are empty. Legacy macro arity is `unknown`, even if a clause
looks fixed-arity. Empty producer doc lists remain `none`. Lodox interpreted
these docstrings as Markdown.

The selection order is embedded `Docs`, an associated sidecar under the
immediate package root, then `LDoc` from the same BEAM bytes. Only an exact
`missing_docs` result from sidecar selection advances to `LDoc`; present invalid
Docs, sidecar read failures, and rejected sidecar associations stay errors. A
missing `LDoc` chunk returns `missing_docs`; a malformed or unsupported
versioned payload returns `invalid_ldoc`. The `LDoc` adapter preserves
producer patterns as data and does not execute them.

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

For sidecars, ldoc uses the module identity read from the supplied BEAM and
checks only the immediate package root above its `ebin` directory. It does not
infer identity from the filename, walk ancestors, or consult the VM code path.
Embedded docs are authoritative, including `hidden` and `none`; only a missing
embedded chunk advances to the sidecar. A malformed embedded chunk remains
`invalid_docs` even if a sidecar exists.

Filesystem errors retain tagged reasons (`read_beam` or `read_sidecar`).
Invalid BEAMs, missing docs, invalid docs, invalid package associations, and
invalid EDoc provenance have distinct tagged errors. Sidecars contain no
module/build identity to authenticate their contents, so collection assumes a
trusted package with stable contents. Do not use this reader for hostile or
public artifacts; atom creation and resource bounds need a separate isolation
design.
