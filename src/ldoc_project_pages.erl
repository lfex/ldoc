%% Project-facing adapter from literal Rebar configuration to portable pages.
-module(ldoc_project_pages).

-moduledoc """
Load the selected Markdown documents for one trusted project build.

`load/4` reads the literal top-level `rebar.config` terms, validates every
configured page declaration, applies an optional ordered CLI replacement,
then reads only the effective files. Physical filenames retain their input
Unicode; logical identities are canonicalised by `ldoc-pages`.
""".

-include_lib("kernel/include/file.hrl").

-export([load/4]).

-doc """
Load selected pages for an absolute project root. `Override` is `absent` or
an ordered list of project-relative path strings; `OverviewPath` is the
resolved physical overview filename; `Alias` is `undefined` or its explicit
logical project-relative identity. Returns legacy empty options or portable
renderer options, and tagged config, overview, or input errors.
""".
-spec load(file:filename_all(), absent | [string()], file:filename_all(),
           undefined | string()) -> {ok, map()} | {error, term()}.
load(Project, Override, OverviewPath, Alias)
  when is_list(Project), is_list(OverviewPath),
       (Override =:= absent orelse is_list(Override)),
       (Alias =:= undefined orelse is_list(Alias)) ->
    ConfigPath = filename:join(Project, "rebar.config"),
    case read_config(ConfigPath) of
        {error, _} = Error -> Error;
        {ok, Configured} ->
            case effective_pages(Override, Configured) of
                {error, _} = Error -> Error;
                {ok, absent} when Alias =:= undefined -> {ok, #{}};
                {ok, absent} -> page_error(overview, Alias, alias_without_pages);
                {ok, Paths} -> load_pages(Project, Paths, OverviewPath, Alias)
            end
    end;
load(_, _, _, _) -> page_error(config, "rebar.config", invalid_ldoc_config).

read_config(Path) ->
    case file:consult(Path) of
        {error, Reason} -> page_error(config, Path, {consult, Reason});
        {ok, Terms} ->
            Sections = [Term || Term <- Terms, is_ldoc_term(Term)],
            Malformed = lists:any(fun(Term) ->
                is_ldoc_term(Term) andalso
                    not (is_tuple(Term) andalso tuple_size(Term) =:= 2)
            end, Terms),
            case {Malformed, Sections} of
                {true, _} -> page_error(config, Path, invalid_ldoc_config);
                {false, []} -> {ok, absent};
                {false, [_First, _Second | _]} -> page_error(config, Path, duplicate_ldoc);
                {false, [{ldoc, Options}]} -> read_pages_option(Path, Options)
            end
    end.

is_ldoc_term(Term) when is_tuple(Term), tuple_size(Term) > 0 ->
    element(1, Term) =:= ldoc;
is_ldoc_term(ldoc) -> true;
is_ldoc_term(_) -> false.

read_pages_option(Path, Options) when is_list(Options) ->
    case proper_pairs(Options) of
        false -> page_error(config, Path, invalid_ldoc_config);
        true ->
            Keys = [Key || {Key, _} <- Options],
            case [Key || Key <- Keys, Key =/= pages] of
                [Unknown | _] -> page_error(config, Path, {unknown_option, Unknown});
                [] -> case length(Keys) - length(lists:usort(Keys)) of
                    N when N > 0 ->
                        case lists:member(pages, Keys) andalso
                             count(pages, Keys) > 1 of
                            true -> page_error(config, Path, duplicate_pages);
                            false -> page_error(config, Path, invalid_ldoc_config)
                        end;
                    _ -> case proplists:lookup(pages, Options) of
                        none -> {ok, absent};
                        {pages, Paths} -> validate_paths(config, Path, Paths)
                    end
                end
            end
    end;
read_pages_option(Path, _) -> page_error(config, Path, invalid_ldoc_config).

is_pair({_, _}) -> true;
is_pair(_) -> false.
proper_pairs([]) -> true;
proper_pairs([Pair | Rest]) -> is_pair(Pair) andalso proper_pairs(Rest);
proper_pairs(_) -> false.
count(Key, Values) -> length([Value || Value <- Values, Value =:= Key]).

effective_pages(absent, Configured) -> {ok, Configured};
effective_pages(Override, _Configured) ->
    case validate_paths(input, "--page", Override) of
        {ok, Paths} -> {ok, Paths};
        {error, _} = Error ->
            %% Static configuration has already been validated in full.
            Error
    end.

validate_paths(_Stage, _Path, []) -> {ok, []};
validate_paths(Stage, ErrorPath, Paths) when is_list(Paths) ->
    case convert_entries(Paths, []) of
        {ok, Entries} ->
            Metadata = [metadata(Entry) || Entry <- Entries],
            Overview = unique_validation_path([maps:get(identity, E) || E <- Entries], 0),
            case 'ldoc-pages':prepare(Metadata, Overview) of
                {ok, _} -> {ok, Entries};
                {error, _} -> page_error(Stage, invalid_path(Stage, ErrorPath, Paths),
                                         invalid_pages_reason(Stage))
            end;
        error -> page_error(Stage, invalid_path(Stage, ErrorPath, Paths),
                            invalid_pages_reason(Stage))
    end;
validate_paths(Stage, ErrorPath, _) ->
    page_error(Stage, ErrorPath, invalid_pages_reason(Stage)).

invalid_pages_reason(config) -> invalid_pages;
invalid_pages_reason(input) -> invalid_page_metadata.

invalid_path(config, ConfigPath, _Paths) -> ConfigPath;
invalid_path(input, _Default, [Path | _]) when is_list(Path) -> Path;
invalid_path(input, _Default, [{Path, _Title} | _]) when is_list(Path) -> Path;
invalid_path(input, Default, _) -> Default.

convert_entries([], Acc) -> {ok, lists:reverse(Acc)};
convert_entries([Value | Rest], Acc) ->
    case entry(Value) of
        {ok, Entry} -> convert_entries(Rest, [Entry | Acc]);
        error -> error
    end;
convert_entries(_, _) -> error.

entry(Path) when is_list(Path), Path =/= [] ->
    case unicode_binary(Path) of
        {ok, Binary} -> {ok, #{path => Path, identity => Binary}};
        error -> error
    end;
entry({Path, Title}) when is_list(Path), Path =/= [], is_list(Title), Title =/= [] ->
    case {unicode_binary(Path), unicode_binary(Title)} of
        {{ok, Binary}, {ok, TitleBinary}} ->
            {ok, #{path => Path, identity => Binary, title => TitleBinary}};
        _ -> error
    end;
entry(_) -> error.

unicode_binary(Chars) ->
    case flat_charlist(Chars) of
        false -> error;
        true -> try unicode:characters_to_binary(Chars, unicode, utf8) of
        Binary when is_binary(Binary) -> {ok, Binary};
        _ -> error
        catch error:badarg -> error
        end
    end.

flat_charlist([]) -> true;
flat_charlist([C | Rest]) when is_integer(C) -> flat_charlist(Rest);
flat_charlist(_) -> false.

unique_validation_path(Paths, N) ->
    Candidate = unicode:characters_to_binary(
                  "__ldoc_validation_" ++ integer_to_list(N) ++ ".md"),
    case lists:member(Candidate, Paths) of
        true -> unique_validation_path(Paths, N + 1);
        false -> Candidate
    end.

metadata(Entry) ->
    Base = #{path => maps:get(identity, Entry), body => <<>>},
    case maps:find(title, Entry) of
        {ok, Title} -> Base#{title => Title};
        error -> Base
    end.

load_pages(_Project, absent, _OverviewPath, _Alias) -> {ok, #{}};
load_pages(Project, Paths, OverviewPath, Alias) ->
    case overview_identity(Project, OverviewPath, Alias) of
        {error, _} = Error -> Error;
        {ok, OverviewIdentity} ->
            case read_effective(Project, Paths, []) of
                {error, _} = Error -> Error;
                {ok, Pages} ->
                    case 'ldoc-pages':prepare(Pages, OverviewIdentity) of
                        {ok, Prepared} -> {ok, #{pages => Prepared,
                                                overview_path => OverviewIdentity}};
                        {error, _} -> page_error(input, first_path(Paths),
                                                 invalid_page_metadata)
                    end
            end
    end.

first_path([#{path := Path} | _]) -> Path;
first_path(_) -> "--page".

overview_identity(Project, OverviewPath, Alias) ->
    case Alias of
        undefined ->
            case relative_to(Project, OverviewPath) of
                {ok, Relative} -> identity(overview, OverviewPath, Relative);
                outside -> page_error(overview, OverviewPath,
                                      outside_project_requires_alias)
            end;
        _ -> identity(overview, Alias, Alias)
    end.

identity(Stage, ErrorPath, Chars) ->
    case unicode_binary(Chars) of
        {ok, Binary} -> case 'ldoc-pages':'canonical-path'(Binary) of
            {ok, Canonical} -> {ok, Canonical};
            error -> page_error(Stage, ErrorPath, invalid_identity)
        end;
        error -> page_error(Stage, ErrorPath, invalid_identity)
    end.

relative_to(Project, Path) ->
    Root = filename:absname(Project),
    Absolute = filename:absname(Path),
    Prefix = Root ++ [$/],
    case lists:prefix(Prefix, Absolute) of
        true -> {ok, lists:nthtail(length(Prefix), Absolute)};
        false when Absolute =:= Root -> {ok, "README.md"};
        false -> outside
    end.

read_effective(_Project, [], Acc) -> {ok, lists:reverse(Acc)};
read_effective(Project, [Entry | Rest], Acc) ->
    case read_page(Project, Entry) of
        {ok, Page} -> read_effective(Project, Rest, [Page | Acc]);
        {error, _} = Error -> Error
    end.

read_page(Project, Entry) ->
    Path = maps:get(path, Entry),
    Identity = maps:get(identity, Entry),
    case valid_raw_path(Identity) of
        false -> page_error(input, Path, invalid_page_metadata);
        true -> case walk_components(filename:split(Path), Project) of
            {ok, File} -> case file:read_file(File) of
                {ok, Body} -> case unicode:characters_to_binary(Body, utf8, utf8) of
                    B when is_binary(B) ->
                        Page0 = #{path => Identity, body => B},
                        Page = case maps:find(title, Entry) of
                            {ok, Title} -> Page0#{title => Title};
                            error -> Page0
                        end,
                        {ok, Page};
                    _ -> page_error(input, Path, invalid_utf8)
                end;
                {error, Reason} -> page_error(input, Path, {read, Reason})
            end;
            {error, _} = Error -> Error
        end
    end.

valid_raw_path(Identity) ->
    case 'ldoc-pages':'canonical-path'(Identity) of {ok, _} -> true; _ -> false end.

walk_components([], Current) -> {ok, Current};
walk_components([Component | Rest], Current) ->
    Next = filename:join(Current, Component),
    case file:read_link_info(Next) of
        {error, Reason} -> page_error(input, Next, {inspect, Reason});
        {ok, #file_info{type = symlink}} ->
            page_error(input, Next, {unsafe_component, symlink});
        {ok, #file_info{type = directory}} when Rest =/= [] ->
            walk_components(Rest, Next);
        {ok, #file_info{type = regular}} when Rest =:= [] -> {ok, Next};
        {ok, #file_info{type = Type}} ->
            page_error(input, Next, {unsafe_component, Type})
    end.

page_error(Stage, Path, Reason) ->
    {error, {documentation_pages, {Stage, Path, Reason}}}.
