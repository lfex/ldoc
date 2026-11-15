# ldoc maintainer guide

## Advanced output behavior

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

## Install the standalone command from a source checkout

For development, install the current checkout directly. `make check` is a
separate optional compile-and-test gate, not a prerequisite hidden in the
install recipe.

```sh
make install PREFIX="$HOME/.local"
"$HOME/.local/bin/ldoc" --help
```

## Maintainer package and docs checks

The ordinary `{ldoc, [{pages, [...]}]}` configuration in the checkout selects
`docs/guide.md` followed by `docs/maintainers.md`. Both `make docs` and the
preparation stage of `make publish` use that same selection and identify
`docs/overview.md` explicitly as the overview source. Change the shared
configuration when adjusting the maintained reference; do not maintain a
separate page list in the Make recipes.

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
The package contains the application source, tests, README, `docs/overview.md`,
`docs/guide.md`, `docs/maintainers.md`, LICENSE, Makefile, and Rebar
configuration/lock. The companion docs package is generated
from the same versioned site used by the combined provider. These source/docs
artifacts describe the release; ldoc does not provide a prebuilt executable
through this workflow.

