%% Rebar3 provider adapter for the standalone ldoc pipeline.
-module(ldoc_prv).

-moduledoc "Run ldoc from an ordinary Rebar3 project.".

-include_lib("kernel/include/file.hrl").

-export([init/1, do/1, format_error/1]).

-define(OWNER, <<"ldoc-rebar3-output-v1\n">>).
-define(GENERATION, <<"ldoc-rebar3-generation-v1\n">>).

-doc "Create the default-namespace, dependency-free ldoc provider.".
-spec init(rebar_state:t()) -> {ok, rebar_state:t()}.
init(State) ->
    Providers = providers:create([
        {name, ldoc},
        {module, ?MODULE},
        {bare, true},
        {deps, []},
        {example, "rebar3 ldoc"},
        {short_desc, "Build a native Erlang and LFE reference"},
        {desc, "Builds the current flat default-profile project and refreshes the ldoc reference."},
        {opts, [{output, $o, "output", string, "Fresh explicit output root"},
                {overview, undefined, "overview", string, "Overview Markdown file"},
                {overview_path, undefined, "overview-path", string, "Overview logical identity"},
                {page, undefined, "page", string, "Selected project Markdown page (repeatable)"},
                {namespace, undefined, "namespace", string, "Release namespace"},
                {package, undefined, "package", string, "Package label"},
                {source_root, undefined, "source-root", string, "Source link root"},
                {source_base, undefined, "source-base", string, "Source link base URL"}]}
    ]),
    {ok, rebar_state:add_provider(State, Providers)}.

-doc "Build documentation for the current default-profile project.".
-spec do(rebar_state:t()) -> {ok, rebar_state:t()} | {error, {ldoc_prv, term()}}.
do(State) ->
    case rebar_state:current_profiles(State) of
        [default] -> do_default(State);
        Profiles -> {error, {?MODULE, {unsupported_profiles, Profiles}}}
    end.

do_default(State) ->
    Args = rebar_state:command_parsed_args(State),
    Root = rebar_state:dir(State),
    case rebar_state:escript_path(State) of
        Rebar3 when is_list(Rebar3) ->
            AbsoluteRebar3 = filename:absname(Rebar3),
            run_provider(State, Root, Args, AbsoluteRebar3);
        Other -> {error, {?MODULE, {invalid_rebar3_executable, Other}}}
    end.

run_provider(State, Root, Args, Rebar3) ->
    case provider_options(Args) of
        {error, Reason} -> {error, {?MODULE, Reason}};
        {ok, Options} ->
            case maps:find(output, Options) of
                {ok, Output} -> run_explicit(State, Root, Output, Options, Rebar3);
                error ->
                    Container = filename:join([Root, "_build", "default", "ldoc"]),
                    case build_default(Container, Root, Options, Rebar3) of
                        {ok, Index} -> report_success(State, Index);
                        {error, Reason} -> {error, {?MODULE, Reason}}
                    end
            end
    end.

run_explicit(State, Root, Output, Options, Rebar3) ->
    Args = build_args(Root, Output, Options),
    case ldoc_cli:run(Args, #{rebar3 => Rebar3}) of
        {ok, Index} -> report_success(State, Index);
        {error, Reason} -> {error, {?MODULE, Reason}}
    end.

report_success(State, Index) ->
    rebar_api:info("ldoc reference: ~ts", [unicode:characters_to_list(Index)]),
    {ok, State}.

provider_options({[help], []}) -> {error, help_requested};
provider_options({Options, []}) when is_list(Options) ->
    try {ok, lists:foldl(fun provider_option/2, #{}, Options)}
    catch throw:Reason -> {error, Reason}; error:Reason -> {error, {invalid_options, Reason}}
    end;
provider_options({_Options, Positionals}) when is_list(Positionals), Positionals =/= [] ->
    {error, {unexpected_arguments, Positionals}};
provider_options(Args) -> {error, {invalid_options, Args}}.

provider_option({output, Value}, Acc) -> put_option("--output", Value, Acc);
provider_option({overview, Value}, Acc) -> put_option("--overview", Value, Acc);
provider_option({overview_path, Value}, Acc) -> put_option("--overview-path", Value, Acc);
provider_option({page, Value}, Acc) -> put_page(Value, Acc);
provider_option({namespace, Value}, Acc) -> put_option("--namespace", Value, Acc);
provider_option({package, Value}, Acc) -> put_option("--package", Value, Acc);
provider_option({source_root, Value}, Acc) -> put_option("--source-root", Value, Acc);
provider_option({source_base, Value}, Acc) -> put_option("--source-base", Value, Acc);
provider_option({Key, _Value}, _Acc) -> throw({unsupported_option, Key});
provider_option(Other, _Acc) -> throw({invalid_option, Other}).

put_page(Value, Acc) when is_list(Value), Value =/= [] ->
    Acc#{pages => maps:get(pages, Acc, []) ++ [Value]};
put_page(Value, _Acc) -> throw({invalid_option_value, "--page", Value}).

put_option(Flag, Value, Acc) when is_list(Value), Value =/= [] ->
    Key = option_key(Flag),
    case maps:is_key(Key, Acc) of
        true -> throw({duplicate_option, Flag});
        false -> maps:put(Key, Value, Acc)
    end;
put_option(Flag, Value, _Acc) -> throw({invalid_option_value, Flag, Value}).

option_key("--output") -> output;
option_key("--overview") -> overview;
option_key("--overview-path") -> overview_path;
option_key("--namespace") -> namespace;
option_key("--package") -> package;
option_key("--source-root") -> source_root;
option_key("--source-base") -> source_base.

build_args(Root, Output, Options) ->
    ["build", Root, "--output", Output] ++ option_args(maps:remove(output, Options)).

option_args(Options) ->
    Single = lists:append([[option_flag(Key), maps:get(Key, Options)]
                           || Key <- [overview, overview_path, namespace, package,
                                      source_root, source_base],
                              maps:is_key(Key, Options)]),
    Single ++ lists:append([["--page", Path] || Path <- maps:get(pages, Options, [])]).

option_flag(overview) -> "--overview";
option_flag(overview_path) -> "--overview-path";
option_flag(namespace) -> "--namespace";
option_flag(package) -> "--package";
option_flag(source_root) -> "--source-root";
option_flag(source_base) -> "--source-base".

build_default(Container, Root, Options, Rebar3) ->
    case ensure_build_ancestors(Root) of
        ok ->
            case claim_container(Container) of
                ok -> with_lock(Container, fun() ->
                    case inspect_current(Container) of
                        {error, _} = Error -> Error;
                        {ok, Previous} -> build_generation(Container, Root, Options,
                                                           Rebar3, Previous)
                    end
                end);
                Error -> Error
            end;
        Error -> Error
    end.

ensure_build_ancestors(Root) ->
    Build = filename:join(Root, "_build"),
    Default = filename:join(Build, "default"),
    case ensure_ordinary_directory(Build) of
        ok -> ensure_ordinary_directory(Default);
        Error -> Error
    end.

ensure_ordinary_directory(Path) ->
    case file:read_link_info(Path) of
        {ok, #file_info{type = directory}} -> ok;
        {ok, _} -> {error, {unsafe_ancestor, Path}};
        {error, enoent} ->
            case file:make_dir(Path) of
                ok -> ok;
                {error, eexist} -> ensure_ordinary_directory(Path);
                {error, Reason} -> {error, {create_ancestor, Path, Reason}}
            end;
        {error, Reason} -> {error, {inspect_ancestor, Path, Reason}}
    end.

claim_container(Container) ->
    case file:make_dir(Container) of
        ok ->
            case file:write_file(filename:join(Container, ".ldoc-owner"), ?OWNER,
                                 [binary, exclusive]) of
                ok -> ok;
                {error, Reason} -> {error, {owner_marker_write, Container, Reason}}
            end;
        {error, eexist} -> validate_container(Container);
        {error, Reason} -> {error, {container_create, Container, Reason}}
    end.

validate_container(Container) ->
    case file:read_link_info(Container) of
        {ok, #file_info{type = directory}} ->
            Marker = filename:join(Container, ".ldoc-owner"),
            case file:read_link_info(Marker) of
                {ok, #file_info{type = regular}} ->
                    case file:read_file(Marker) of
                        {ok, ?OWNER} -> ok;
                        _ -> {error, {unowned_container, Container}}
                    end;
                _ -> {error, {unowned_container, Container}}
            end;
        {ok, _} -> {error, {unsafe_container, Container}};
        {error, Reason} -> {error, {container_inspect, Container, Reason}}
    end.

with_lock(Container, Fun) ->
    Lock = filename:join(Container, ".ldoc-lock"),
    Token = list_to_binary(io_lib:format("~p~n", [make_ref()])),
    case file:write_file(Lock, Token, [binary, exclusive]) of
        ok -> try Fun() after release_lock(Lock, Token) end;
        {error, eexist} -> {error, {locked_or_stale_lock, Lock}};
        {error, Reason} -> {error, {lock_create, Lock, Reason}}
    end.

release_lock(Lock, Token) ->
    case file:read_link_info(Lock) of
        {ok, #file_info{type = regular}} ->
            case file:read_file(Lock) of
                {ok, Token} -> file:delete(Lock);
                _ -> ok
            end;
        _ -> ok
    end.

inspect_current(Container) ->
    Current = filename:join(Container, "current"),
    case file:read_link_info(Current) of
        {error, enoent} -> {ok, absent};
        {ok, #file_info{type = symlink}} ->
            case file:read_link(Current) of
                {ok, Target} -> validate_current_target(Container, Target);
                {error, Reason} -> {error, {invalid_current, Current, Reason}}
            end;
        {ok, _} -> {error, {invalid_current, Current, not_symlink}};
        {error, Reason} -> {error, {invalid_current, Current, Reason}}
    end.

validate_current_target(Container, Target) ->
    case {filename:pathtype(Target), filename:split(Target)} of
        {relative, [Generation, "reference"]} ->
            case lists:prefix("gen-", Generation) andalso
                 not lists:member("..", filename:split(Target)) of
                true -> validate_generation(Container, Generation);
                false -> {error, {invalid_current_target, Target}}
            end;
        _ -> {error, {invalid_current_target, Target}}
    end.

validate_generation(Container, Generation) ->
    GenPath = filename:join(Container, Generation),
    Marker = filename:join(GenPath, ".ldoc-generation"),
    Ref = filename:join(GenPath, "reference"),
    case {file:read_link_info(GenPath), generation_contents(GenPath),
          file:read_link_info(Marker), file:read_link_info(Ref)} of
        {{ok, #file_info{type = directory}}, ok,
         {ok, #file_info{type = regular}}, {ok, #file_info{type = directory}}} ->
            case file:read_file(Marker) of
                {ok, ?GENERATION} -> {ok, {present, Generation}};
                _ -> {error, {invalid_current_generation, Generation}}
            end;
        _ -> {error, {invalid_current_generation, Generation}}
    end.

generation_contents(Path) ->
    case file:list_dir(Path) of
        {ok, [".ldoc-generation", "reference"]} -> ok;
        {ok, ["reference", ".ldoc-generation"]} -> ok;
        _ -> error
    end.

build_generation(Container, Root, Options, Rebar3, Previous) ->
    case create_generation(Container) of
        {error, _} = Error -> Error;
        {ok, Generation} ->
            Ref = filename:join([Container, Generation, "reference"]),
            Args = build_args(Root, Ref, Options),
            case ldoc_cli:run(Args, #{rebar3 => Rebar3}) of
                {error, Reason} -> {error, {build_failed, Reason}};
                {ok, Index} -> switch_current(Container, Generation, Ref, Index, Previous)
            end
    end.

create_generation(Container) ->
    Candidate = "gen-" ++ integer_to_list(erlang:unique_integer([positive, monotonic])),
    Path = filename:join(Container, Candidate),
    case file:make_dir(Path) of
        ok ->
            case file:write_file(filename:join(Path, ".ldoc-generation"), ?GENERATION,
                                 [binary, exclusive]) of
                ok -> {ok, Candidate};
                {error, Reason} -> {error, {generation_marker_write, Path, Reason}}
            end;
        {error, eexist} -> create_generation(Container);
        {error, Reason} -> {error, {generation_create, Path, Reason}}
    end.

switch_current(Container, Generation, Ref, Index, Previous) ->
    case inspect_current(Container) of
        {ok, Previous} ->
            case filelib:is_regular(Index) of
                false -> {error, {build_index_missing, Index}};
                true -> atomic_current(Container, Generation, Ref)
            end;
        {ok, Now} -> {error, {current_changed_during_build, Previous, Now}};
        {error, Reason} -> {error, Reason}
    end.

atomic_current(Container, Generation, Ref) ->
    Temp = filename:join(Container, ".current-" ++
                         integer_to_list(erlang:unique_integer([positive, monotonic]))),
    Target = filename:join(Generation, "reference"),
    case file:make_symlink(Target, Temp) of
        ok ->
            try case file:rename(Temp, filename:join(Container, "current")) of
                ok -> {ok, unicode:characters_to_binary(
                             filename:join([Container, "current", "site", "index.html"]))};
                {error, Reason} -> {error, {current_switch, Ref, Reason}}
            end after cleanup_temp_link(Temp, Target) end;
        {error, Reason} -> {error, {current_link_create, Temp, Reason}}
    end.

cleanup_temp_link(Temp, Target) ->
    case {file:read_link_info(Temp), file:read_link(Temp)} of
        {{ok, #file_info{type = symlink}}, {ok, Target}} -> file:delete(Temp);
        _ -> ok
    end.

-doc "Format provider failures as concise actionable Unicode text.".
-spec format_error(term()) -> unicode:chardata().
format_error({unsupported_profiles, Profiles}) ->
    io_lib:format("ldoc supports only the default Rebar profile; active profiles: ~tp", [Profiles]);
format_error({locked_or_stale_lock, Lock}) ->
    io_lib:format("ldoc output is locked at ~ts; confirm no build is active, then inspect and remove a stale lock", [Lock]);
format_error({unowned_container, Path}) ->
    io_lib:format("refusing unowned ldoc output container ~ts; contents were left untouched", [Path]);
format_error(Reason) -> io_lib:format("ldoc provider failed: ~tp", [Reason]).
