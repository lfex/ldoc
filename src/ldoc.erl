%% Thin Rebar3 plugin entrypoint for ldoc.
-module(ldoc).

-moduledoc "Register the ldoc Rebar3 provider.".

-export([init/1]).

-doc "Register the ldoc provider in Rebar3 state.".
-spec init(term()) -> {ok, term()}.
init(State) ->
    {ok, rebar_state:add_provider(State, ldoc_prv:init(State))}.
