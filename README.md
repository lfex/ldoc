# ldoc

This source builds ldoc 0.1.1, which collects API documentation for Erlang,
modern LFE, and classic LFE from trusted local BEAM artifacts. It assembles
native snapshots and renders a static HTML reference.

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
The plugin builds the default profile and leaves the application's normal
compiler settings intact. Rebar3
3.28.0 is the verified provider version. Erlang source-comment conversion
requires OTP's `edoc_doclet_chunks` and `edoc_layout_chunks` tools. Use
`rebar3 help ldoc` for provider options. ldoc is development-only and does not
become a runtime dependency of the documented application.

## Documentation

Select project Markdown pages with the ordinary `{ldoc, [{pages, [...]}]}`
setting in `rebar.config`; see the [page selection guide](docs/guide.md#select-project-markdown-pages).

- [User guide](docs/guide.md): collection, snapshots, analysis, and rendering.
- [Maintainer guide](docs/maintainers.md): output behavior, standalone
  installation, and package publishing.
