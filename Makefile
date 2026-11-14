REBAR3 ?= rebar3
PREFIX ?= $(HOME)/.local
BIN_NAME = ldoc
DOCGEN ?= $(CURDIR)/_build/default/bin/ldoc
DOCS_PARENT ?= $(CURDIR)/_build/ldoc
PUBLISH_FLAGS ?=

.PHONY: help compile test check cli install docs publish

help:
	@printf '%s\n' 'make compile  Compile the ldoc library and command' \
	  'make test     Run the complete EUnit suite' \
	  'make check    Compile, test, and build the escript' \
	  'make cli      Build _build/default/bin/ldoc' \
	  'make install  Install the standalone command under PREFIX/bin' \
	  'make docs     Build and retain a fresh local HTML reference' \
	  'make publish  Publish source and generated docs together (PUBLISH_FLAGS can pass provider options)'

compile:
	$(REBAR3) compile

test:
	$(REBAR3) eunit

cli: compile
	$(REBAR3) lfe escriptize

check:
	$(MAKE) compile
	$(MAKE) test
	$(MAKE) cli

install: cli
	mkdir -p "$(PREFIX)/bin"
	cp "_build/default/bin/$(BIN_NAME)" "$(PREFIX)/bin/$(BIN_NAME)"
	chmod 755 "$(PREFIX)/bin/$(BIN_NAME)"

docs: cli
	@set -eu; \
	  mkdir -p "$(DOCS_PARENT)"; \
	  docs_work="$$(mktemp -d "$(DOCS_PARENT)/docs.XXXXXXXX")"; \
	  "$(DOCGEN)" build "$(CURDIR)" --output "$$docs_work/reference" \
	    --overview "$(CURDIR)/docs/overview.md" \
	    --namespace hexpm --package ldoc

publish: cli
	@set -eu; \
	  mkdir -p "$(DOCS_PARENT)"; \
	  publish_work="$$(mktemp -d "$(DOCS_PARENT)/publish.XXXXXXXX")"; \
	  trap 'rm -rf -- "$$publish_work"' EXIT; \
	  "$(DOCGEN)" build "$(CURDIR)" --output "$$publish_work/reference" \
	    --overview "$(CURDIR)/docs/overview.md" \
	    --namespace hexpm --package ldoc; \
	  "$(REBAR3)" hex publish --doc-dir "$$publish_work/reference/site" $(PUBLISH_FLAGS)
