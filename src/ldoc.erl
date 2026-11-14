%% Thin Rebar3 plugin entrypoint for ldoc.
-module(ldoc).

-moduledoc "Register the ldoc Rebar3 provider.".

-export([init/1]).

-doc "Register the ldoc provider in Rebar3 state.".
-spec init(rebar_state:t()) -> {ok, rebar_state:t()}.
init(State) -> ldoc_prv:init(State).
