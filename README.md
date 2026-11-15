# ldoc

[![Build Status][gh-actions-badge]][gh-actions]
[![LFE Version][lfe-badge]][lfe]
[![Erlang/OTP Versions][erlang-badge]][versions]
[![Tags][github-tags-badge]][github-tags]
[![Downloads][hex-downloads]][hex-package]
[![HexDocs][hex-docs-badge]][hex-docs]

[![][logo]][logo-large]

*An LFE port of Clojure's cljdoc*

ldoc turns the documentation in Erlang and LFE projects into an easy-to-browse website. It brings API references, guides, and other project pages together, helping people find what they need, understand how a library works, and get started using it.

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

## Licence

ldoc is released under the [Apache License, Version 2.0](LICENSE).

The project image featuring LiffyBot (the LFE mascot) was
inspired by [Andrea Wisnewski's linocut prints](https://runningrabbit.biz/linocut-prints/).

[//]: ---Named-Links---

[logo-large]: priv/images/ldoc-liffybot.png
[logo]: priv/images/ldoc-liffybot-y250.png
[gh-actions-badge]: https://github.com/lfex/ldoc/actions/workflows/cicd.yml/badge.svg?branch=main
[gh-actions]: https://github.com/lfex/ldoc/actions/workflows/cicd.yml?query=branch%3Amain
[lfe]: https://github.com/lfe/lfe
[lfe-badge]: https://img.shields.io/badge/LFE-2.2+-blue.svg
[versions]: https://github.com/lfex/ldoc/blob/main/.github/workflows/cicd.yml
[erlang-badge]: https://img.shields.io/badge/Erlang%2FOTP-27%E2%80%9329-blue.svg
[hex-package]: https://hex.pm/packages/ldoc
[hex-badge]: https://img.shields.io/hexpm/v/ldoc.svg
[github-tags]: https://github.com/lfex/ldoc/tags
[github-tags-badge]: https://img.shields.io/github/v/tag/lfex/ldoc.svg?sort=semver
[hex-downloads]: https://img.shields.io/hexpm/dt/ldoc.svg
[hex-docs]: https://hexdocs.pm/ldoc/
[hex-docs-badge]: https://img.shields.io/badge/hex-docs-blue.svg
