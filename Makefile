REBAR3 ?= rebar3
PREFIX ?= $(HOME)/.local
BIN_NAME = ldoc

.PHONY: help compile test check cli install

help:
	@printf '%s\n' 'make compile  Compile the ldoc library and command' \
	  'make test     Run the complete EUnit suite' \
	  'make check    Compile, test, and build the escript' \
	  'make cli      Build _build/default/bin/ldoc' \
	  'make install  Install the standalone command under PREFIX/bin'

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
