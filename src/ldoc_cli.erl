%% A standalone command for building a trusted flat local application.
-module(ldoc_cli).

-moduledoc """
Build a local reference site and native EEP-48 snapshot from a flat rebar3
application. The command compiles the project as a child process and does not
load or start the target application.
""".

-include_lib("kernel/include/file.hrl").

-export([main/1, run/1]).

-doc """
Run the command-line entry point for `ldoc`.

`Args` contains the escript arguments. This command requires UTF-8 native
filename encoding and configures its standard output and error streams for
Unicode before parsing or building. It prints help or the published index path
to standard output, writes diagnostics to standard error, and halts with
status 0, 1, or 2. It is the only API function that halts the BEAM process.
""".
-spec main([string()]) -> no_return().
main(Args) ->
    case file:native_name_encoding() of
        utf8 ->
            case set_command_io_encoding() of
                ok -> main_result(run(Args));
                {error, Reason} ->
                    io:put_chars(standard_error,
                                 ["ldoc: ", format_reason({runtime, {io_encoding, Reason}}), "\n"]),
                    halt(1)
            end;
        Encoding ->
            io:put_chars(standard_error,
                         ["ldoc: ",
                          format_reason({runtime, {unsupported_native_encoding, Encoding}}),
                          "\n"]),
            halt(1)
    end.

set_command_io_encoding() ->
    case io:setopts(standard_io, [{encoding, unicode}]) of
        ok ->
            case io:setopts(standard_error, [{encoding, unicode}]) of
                ok -> ok;
                {error, Reason} -> {error, {standard_error, Reason}}
            end;
        {error, Reason} -> {error, {standard_io, Reason}}
    end.

main_result(Result) ->
    case Result of
        {ok, help} ->
            io:put_chars("ldoc build PROJECT --output FRESH_ROOT [OPTIONS]\n"
                         "ldoc --help | help\n"
                         "OPTIONS: --overview FILE --namespace TEXT "
                         "--package TEXT --source-root ROOT "
                         "--source-base URL\n"),
            halt(0);
        {ok, Index} ->
            io:put_chars([Index, <<"\n">>]),
            halt(0);
        {error, {usage, Reason}} ->
            io:put_chars(standard_error,
                         ["ldoc: ", format_reason(Reason), "\n",
                          "usage: ldoc build PROJECT --output FRESH_ROOT "
                          "[OPTIONS]\n"]),
            halt(2);
        {error, Reason} ->
            io:put_chars(standard_error,
                         ["ldoc: ", format_reason(Reason), "\n"]),
            halt(1)
    end.

-doc """
Run one command without halting the caller.

Accepts escript arguments including `--help` or `build PROJECT --output ROOT`
and the documented optional build settings. On success returns `{ok, help}`
for help or `{ok, IndexBinary}` containing the absolute `site/index.html`
path. On expected failures it returns `{error, Reason}`. A build starts ldoc's
own required applications, compiles the target with a child `rebar3` process,
may create a fresh output tree, and writes child progress to standard error;
it never starts or loads the target application. It preserves caller IO,
filename encoding, code path, environment, and group leader on return; EDoc's
bracketed diagnostic redirection is restored on both success and failure.
""".
-spec run([string()]) -> {ok, help | binary()} | {error, term()}.
run(["--help"]) -> {ok, help};
run(["help"]) -> {ok, help};
run(["build" | Args]) ->
    case parse_build_args(Args) of
        {ok, Opts} -> build(Opts);
        {error, Reason} -> {error, {usage, Reason}}
    end;
run(_) -> {error, {usage, expected_build}}.

parse_build_args([Project | Args]) when Project =/= "", Project =/= "--output" ->
    case lists:prefix("--", Project) of
        true -> {error, missing_project};
        false -> parse_options(Args, #{project => Project}, [])
    end;

parse_build_args(_) -> {error, missing_project}.

parse_options([], Opts, []) ->
    case maps:is_key(output, Opts) of
        true -> {ok, Opts};
        false -> {error, missing_output}
    end;
parse_options([], _Opts, [Flag | _]) -> {error, {missing_value, Flag}};
parse_options([Flag], _Opts, [])
  when Flag =:= "--output"; Flag =:= "--overview"; Flag =:= "--namespace";
       Flag =:= "--package"; Flag =:= "--source-root"; Flag =:= "--source-base" ->
    {error, {missing_value, Flag}};
parse_options([Flag, Value | Rest], Opts, _Pending)
  when Flag =:= "--output"; Flag =:= "--overview"; Flag =:= "--namespace";
       Flag =:= "--package"; Flag =:= "--source-root"; Flag =:= "--source-base" ->
    Key = option_key(Flag),
    case {Value =/= "" andalso not lists:prefix("--", Value), maps:is_key(Key, Opts)} of
        {false, _} -> {error, {empty_value, Flag}};
        {_, true} -> {error, {duplicate_option, Flag}};
        {true, false} -> parse_options(Rest, maps:put(Key, Value, Opts), [])
    end;
parse_options([Flag | _], _Opts, _Pending) when is_list(Flag) ->
    {error, {unknown_or_missing_option, Flag}}.

option_key("--output") -> output;
option_key("--overview") -> overview;
option_key("--namespace") -> namespace;
option_key("--package") -> package;
option_key("--source-root") -> source_root;
option_key("--source-base") -> source_base.

build(Opts) ->
    Cwd = filename:absname("."),
    RawProject = maps:get(project, Opts),
    RawOutput = maps:get(output, Opts),
    case has_parent_traversal(RawProject) orelse has_parent_traversal(RawOutput) of
        true -> {error, {usage, parent_traversal}};
        false -> build_paths(Opts, Cwd)
    end.

build_paths(Opts, Cwd) ->
    case application:ensure_all_started(ldoc) of
        {ok, _Started} ->
            Project = filename:absname(maps:get(project, Opts), Cwd),
            Output = filename:absname(maps:get(output, Opts), Cwd),
            case validate_prebuild(Project, Output, Opts) of
                {error, Reason} -> {error, Reason};
                {ok, Sources, AppSrc, Overview, ReleaseSeed, SiteOptions} ->
                    case compile_project(Project) of
                        {error, Reason} -> {error, Reason};
                        ok -> build_compiled(Project, Output, Sources, AppSrc,
                                             Overview, ReleaseSeed, SiteOptions)
                    end
            end;
        {error, Reason} -> {error, {runtime, ldoc, Reason}}
    end.

validate_prebuild(Project, Output, Opts) ->
    case file:read_file_info(Project) of
        {ok, #file_info{type = directory}} ->
            validate_project_layout(Project, Output, Opts);
        {ok, _} -> {error, {project, Project, not_directory}};
        {error, Reason} -> {error, {project, Project, Reason}}
    end.

validate_project_layout(Project, Output, Opts) ->
    Config = filename:join(Project, "rebar.config"),
    Src = filename:join(Project, "src"),
    AppFiles = filelib:wildcard(filename:join(Src, "*.app.src")),
    Sources = lists:sort(filelib:wildcard(filename:join(Src, "*.erl")) ++
                         filelib:wildcard(filename:join(Src, "*.lfe"))),
    case {filelib:is_regular(Config), filelib:is_dir(Src), AppFiles, Sources} of
        {false, _, _, _} -> {error, {project, Config, missing_rebar_config}};
        {_, false, _, _} -> {error, {project, Src, missing_source_directory}};
        {_, _, [AppSrc], [_ | _]} ->
            case validate_output(Output) of
                ok -> validate_overview(Project, Opts, Sources, AppSrc);
                Error -> Error
            end;
        {_, _, [], _} -> {error, {project, Src, missing_application_resource}};
        {_, _, [_ | _], []} -> {error, {project, Src, no_source_modules}};
        {_, _, _, _} -> {error, {project, Src, unsupported_layout}}
    end.

validate_output(Output) ->
    Parent = filename:dirname(Output),
    case {has_parent_traversal(Output), file:read_link_info(Output),
          file:read_file_info(Parent)} of
        {true, _, _} -> {error, {output, Output, parent_traversal}};
        {false, {error, enoent}, {ok, #file_info{type = directory}}} -> ok;
        {false, {ok, _}, _} -> {error, {output, Output, output_exists}};
        {false, {error, enoent}, {ok, _}} -> {error, {output, Parent, not_directory}};
        {false, {error, enoent}, {error, Reason}} -> {error, {output, Parent, Reason}};
        {false, {error, Reason}, _} -> {error, {output, Output, Reason}}
    end.

has_parent_traversal(Path) -> lists:member("..", filename:split(Path)).

validate_overview(Project, Opts, Sources, AppSrc) ->
    RawOverview = maps:get(overview, Opts, undefined),
    case RawOverview =/= undefined andalso has_parent_traversal(RawOverview) of
        true -> {error, {overview, RawOverview, parent_traversal}};
        false -> validate_overview_path(Project, Opts, Sources, AppSrc)
    end.

validate_overview_path(Project, Opts, Sources, AppSrc) ->
    OverviewPath = case maps:find(overview, Opts) of
        {ok, Path} -> filename:absname(Path, filename:absname("."));
        error -> filename:join(Project, "README.md")
    end,
    Overview = case {maps:is_key(overview, Opts), file:read_file(OverviewPath)} of
        {false, {error, enoent}} -> {ok, <<>>};
        {_, {ok, ReadBytes}} -> {ok, ReadBytes};
        {true, {error, OverviewError}} -> {error, {overview, OverviewPath, OverviewError}};
        {false, {error, OverviewError}} -> {error, {overview, OverviewPath, OverviewError}}
    end,
    case {read_app_source(AppSrc), Overview} of
        {{ok, App}, {ok, Bytes0}} ->
            Namespace = maps:get(namespace, Opts, "local"),
            SourceRoot = maps:get(source_root, Opts, undefined),
            SourceBase = maps:get(source_base, Opts, undefined),
            RenderOpts = render_options(Bytes0, SourceBase),
            case 'ldoc-html':'valid-options?'(RenderOpts) andalso valid_source_root(SourceRoot) of
                true -> {ok, Sources, App, Bytes0,
                         #{namespace => Namespace,
                           package_override => maps:get(package, Opts, undefined)},
                         #{source_root => source_root_abs(SourceRoot, filename:absname(".")),
                           source_base => optional_binary(SourceBase)}};
                false -> {error, invalid_source_or_render_options}
            end;
        {{error, Reason}, _} -> {error, Reason};
        {_, {error, Reason}} -> {error, Reason}
    end.

render_options(Overview, SourceBase) ->
    Base = #{overview => Overview},
    case SourceBase of
        undefined -> Base;
        _ -> Base#{source_base => unicode:characters_to_binary(SourceBase)}
    end.

valid_source_root(undefined) -> true;
valid_source_root(Path) -> (filename:pathtype(Path) =:= absolute orelse
                            filename:pathtype(Path) =:= relative) andalso
                           not has_parent_traversal(Path).
source_root_abs(undefined, _Cwd) -> undefined;
source_root_abs(Path, Cwd) -> filename:absname(Path, Cwd).
optional_binary(undefined) -> undefined;
optional_binary(Value) -> unicode:characters_to_binary(Value).

read_app_source(Path) ->
    case file:consult(Path) of
        {ok, [{application, App, Props}]} when is_atom(App) ->
            {ok, #{name => App, props => Props}};
        {ok, _} -> {error, {project, Path, invalid_application_resource}};
        {error, Reason} -> {error, {project, Path, {read_application_resource, Reason}}}
    end.

compile_project(Project) ->
    case os:find_executable("rebar3") of
        false -> {error, {compile, Project, rebar3_not_found}};
        Rebar3 ->
            Port = open_port({spawn_executable, Rebar3},
                             [binary, exit_status, use_stdio, stderr_to_stdout,
                              {args, ["compile"]}, {cd, Project},
                              {env, [{"ERL_AFLAGS", child_erlang_aflags()}]},
                              {line, 4096}]),
            try wait_compile(Port, Project)
            after close_compile_port(Port)
            end
    end.

child_erlang_aflags() ->
    case os:getenv("ERL_AFLAGS") of
        false -> "+fnu";
        [] -> "+fnu";
        Original -> "+fnu " ++ Original
    end.

close_compile_port(Port) ->
    case erlang:port_info(Port) of
        undefined -> ok;
        _ ->
            try port_close(Port) of
                true -> ok
            catch
                error:badarg -> ok
            end
    end.

wait_compile(Port, Project) ->
    receive
        {Port, {data, {eol, Data}}} ->
            io:put_chars(standard_error, [Data, "\n"]),
            wait_compile(Port, Project);
        {Port, {data, {noeol, Data}}} ->
            io:put_chars(standard_error, Data),
            wait_compile(Port, Project);
        {Port, {exit_status, 0}} -> ok;
        {Port, {exit_status, Status}} -> {error, {compile, Project, {exit_status, Status}}}
    end.

build_compiled(Project, Output, Sources, AppSrc, Overview, ReleaseSeed, SiteOptions) ->
    case compiled_inputs(Project, Sources, AppSrc, ReleaseSeed) of
        {error, Reason} -> {error, Reason};
        {ok, App, Release} ->
            case file:make_dir(Output) of
                ok ->
                    try claimed_build(Project, Output, Sources, App, Release,
                                      Overview, SiteOptions)
                    catch Class:Reason:Stack ->
                        {error, {stage, internal, Output, {Class, Reason, Stack}}}
                    end;
                {error, eexist} -> {error, {output, Output, output_exists}};
                {error, Reason} -> {error, {output, Output, Reason}}
            end
    end.

compiled_inputs(Project, Sources, AppSrc, ReleaseSeed) ->
    AppName = maps:get(name, AppSrc),
    AppDir = filename:join([Project, "_build", "default", "lib", atom_to_list(AppName), "ebin"]),
    AppFile = filename:join(AppDir, atom_to_list(AppName) ++ ".app"),
    case file:consult(AppFile) of
        {ok, [{application, AppName, Props}]} ->
            Modules = proplists:get_value(modules, Props, []),
            Version = proplists:get_value(vsn, Props, undefined),
            Package = proplists:get_value(pkg_name, Props, AppName),
            case valid_identity(Modules, Version, Package) of
                true ->
                    SourceNames = source_module_names(Sources),
                    BeamFiles = lists:sort(filelib:wildcard(filename:join(AppDir, "*.beam"))),
                    case inventory_beams(BeamFiles, AppDir) of
                        {ok, BeamNames} ->
                            case lists:sort(Modules) =:= SourceNames andalso
                                 lists:sort(Modules) =:= BeamNames of
                                true ->
                                    case check_beam_identities(BeamFiles, []) of
                                        {ok, Checked} ->
                                            Namespace = maps:get(namespace, ReleaseSeed),
                                            PackageName = maps:get(package_override, ReleaseSeed),
                                            Release = #{namespace => unicode:characters_to_binary(Namespace),
                                                        package => package_binary(PackageName, Package),
                                                        version => unicode:characters_to_binary(Version)},
                                            case 'ldoc-docset':'valid-release?'(Release) of
                                                true -> {ok, #{app_dir => AppDir, beams => Checked}, Release};
                                                false -> {error, {identity, AppFile, invalid_release_key}}
                                            end;
                                        Error -> Error
                                    end;
                                false -> {error, {inventory, Project, #{sources => SourceNames,
                                                                        app => lists:sort(Modules),
                                                                        beams => BeamNames}}}
                            end;
                        Error -> Error
                    end;
                false -> {error, {identity, AppFile, invalid_application_identity}}
            end;
        {ok, _} -> {error, {identity, AppFile, invalid_application_file}};
        {error, Reason} -> {error, {identity, AppFile, Reason}}
    end.

valid_identity(Modules, Version, Package) ->
    is_list(Modules) andalso Modules =/= [] andalso is_list(Version) andalso
    Version =/= [] andalso (is_atom(Package) orelse is_list(Package)).

source_module_names(Sources) -> lists:sort([list_to_atom(filename:basename(P, filename:extension(P))) || P <- Sources]).

inventory_beams(Files, AppDir) ->
    Names = [list_to_atom(filename:basename(P, ".beam")) || P <- Files],
    case lists:all(fun filelib:is_regular/1, Files) andalso length(Names) =:= length(lists:usort(Names)) of
        true -> {ok, lists:sort(Names)};
        false -> {error, {inventory, AppDir, invalid_beam_files}}
    end.

check_beam_identities(Files, Acc) ->
    case Files of
        [] -> {ok, lists:reverse(Acc)};
        [Path | Rest] ->
            case file:read_file(Path) of
                {ok, Bytes} ->
                    case beam_lib:chunks(Bytes, []) of
                        {ok, {Module, _}} ->
                            Expected = list_to_atom(filename:basename(Path, ".beam")),
                            case Module =:= Expected of
                                true -> check_beam_identities(Rest, [{Path, Module, Bytes} | Acc]);
                                false -> {error, {identity, Path, {filename_module_mismatch, Module}}}
                            end;
                        {error, beam_lib, Reason} -> {error, {identity, Path, {invalid_beam, Reason}}};
                        {error, Reason} -> {error, {identity, Path, {invalid_beam, Reason}}}
                    end;
                {error, Reason} -> {error, {identity, Path, {read_beam, Reason}}}
            end
    end.

package_binary(undefined, Package) when is_atom(Package) -> atom_to_binary(Package, utf8);
package_binary(undefined, Package) -> unicode:characters_to_binary(Package);
package_binary(Package, _Default) -> unicode:characters_to_binary(Package).

claimed_build(Project, Output, Sources, App, Release, Overview, SiteOptions) ->
    Ebin = filename:join([Output, "package", "ebin"]),
    Doc = filename:join([Output, "package", "doc"]),
    case {filelib:ensure_dir(filename:join(Ebin, "placeholder")),
          filelib:ensure_dir(filename:join(Doc, "placeholder"))} of
        {{error, Reason}, _} -> {error, {stage, package_ebin, Ebin, Reason, Output}};
        {ok, {error, Reason}} -> {error, {stage, package_doc, Doc, Reason, Output}};
        {ok, ok} ->
            Beams = maps:get(beams, App),
            case stage_beams(Beams, Ebin, Project) of
                {error, Reason} -> {error, {stage, copy_beam, Output, Reason}};
                {ok, Staged} ->
                    case generate_missing_docs(Staged, Sources, Project, Doc, Output) of
                        {error, Reason} -> {error, {stage, edoc, Output, Reason}};
                        {ok, Descriptors} ->
                            case 'ldoc-docset':assemble(Release, Descriptors) of
                                {error, Reason} -> {error, {stage, collect, Output, Reason}};
                                {ok, Docset} -> publish_site(Output, Release, Overview,
                                                             SiteOptions, Docset)
                            end
                    end
            end
    end.

stage_beams(Beams, Ebin, _Project) ->
    case lists:foldl(fun({Path, Module, Bytes}, {ok, Acc}) ->
        Dest = filename:join(Ebin, atom_to_list(Module) ++ ".beam"),
        case file:write_file(Dest, Bytes, [binary, exclusive]) of
            ok -> {ok, [{Path, Module, Dest, Bytes} | Acc]};
            {error, Reason} -> {error, {Path, Dest, Reason}}
        end;
       (_, Error) -> Error
    end, {ok, []}, Beams) of
        {ok, Staged} -> {ok, lists:reverse(Staged)};
        Error -> Error
    end.

generate_missing_docs(Staged, Sources, Project, Doc, Output) ->
    generate_missing_docs(Staged, source_map(Sources), Project, Doc, Output, []).

generate_missing_docs([], _SourceMap, _Project, _Doc, _Output, Acc) -> {ok, lists:reverse(Acc)};
generate_missing_docs([{_Original, Module, Staged, Bytes} | Rest], SourceMap, Project, Doc, Output, Acc) ->
    case beam_lib:chunks(Bytes, ["Docs"], [allow_missing_chunks]) of
        {ok, {Module, [{"Docs", missing_chunk}]}} ->
            case maps:find(Module, SourceMap) of
                {ok, Source} ->
                    case filename:extension(Source) of
                        ".erl" ->
                            case edoc_context(Bytes, Project) of
                                {ok, Includes, Macros} ->
                                    case run_edoc(Source, Doc, Includes, Macros) of
                                        ok -> generate_missing_docs(Rest, SourceMap, Project, Doc, Output,
                                                  [{Staged, {edoc, Source, Includes}} | Acc]);
                                        {error, Reason} -> {error, {Source, Reason}}
                                    end;
                                {error, Reason} -> {error, {Source, Reason}}
                            end;
                        ".lfe" -> generate_missing_docs(Rest, SourceMap, Project, Doc, Output,
                                                        [Staged | Acc]);
                        _ -> {error, {Source, no_documentation_carrier}}
                    end;
                error -> {error, {Staged, missing_matching_source}}
            end;
        {ok, {Module, [{"Docs", _Present}]}} ->
            generate_missing_docs(Rest, SourceMap, Project, Doc, Output,
                                  [Staged | Acc]);
        {error, Reason} -> {error, {Staged, {inspect_docs_chunk, Reason}}};
        Other -> {error, {Staged, {inspect_docs_chunk, Other}}}
    end.

source_map(Sources) ->
    maps:from_list([{list_to_atom(filename:basename(Path, filename:extension(Path))),
                     filename:absname(Path)} || Path <- Sources]).

edoc_context(Bytes, Project) ->
    case beam_lib:chunks(Bytes, [compile_info]) of
        {ok, {_Module, [{compile_info, Info}]}} ->
            Options = proplists:get_value(options, Info, []),
            case lists:any(fun({parse_transform, _}) -> true; (_) -> false end, Options) of
                true -> {error, unsupported_parse_transform_context};
                false ->
                    Includes0 = [filename:absname(Path, Project) || {i, Path} <- Options],
                    ProjectInclude = filename:join(Project, "include"),
                    Includes1 = append_existing(ProjectInclude,
                                                 [P || P <- Includes0, filelib:is_dir(P)]),
                    BuildLibs = filename:absname(
                                  filename:join([Project, "_build", "default", "lib"])),
                    Includes = append_existing(BuildLibs, Includes1),
                    Macros = [edoc_macro(Option) || Option <- Options,
                                                    is_edoc_macro(Option)],
                    {ok, Includes, Macros}
            end;
        _ -> {error, unsupported_compile_context}
    end.

append_existing(Path, Paths) ->
    case filelib:is_dir(Path) andalso not lists:member(Path, Paths) of
        true -> Paths ++ [Path];
        false -> Paths
    end.

is_edoc_macro({d, Name}) when is_atom(Name) -> true;
is_edoc_macro({d, Name, _}) when is_atom(Name) -> true;
is_edoc_macro(_) -> false.
edoc_macro({d, Name}) -> {Name, true};
edoc_macro({d, Name, Value}) -> {Name, Value}.

run_edoc(Source, Doc, Includes, Macros) ->
    case {code:lib_dir(edoc), code:which(edoc_doclet_chunks), code:which(edoc_layout_chunks)} of
        {Dir, Doclet, Layout} when is_list(Dir), Doclet =/= non_existing, Layout =/= non_existing ->
            OldLeader = group_leader(),
            StdErr = whereis(standard_error),
            case is_pid(StdErr) of
                false -> {error, standard_error_unavailable};
                true ->
                    try
                        group_leader(StdErr, self()),
                        case edoc:files([Source], [{dir, Doc}, {doclet, edoc_doclet_chunks},
                                                   {layout, edoc_layout_chunks}, {preprocess, true},
                                                   {includes, Includes}, {macros, Macros}]) of
                            ok ->
                                Chunk = filename:join([Doc, "chunks", filename:basename(Source, ".erl") ++ ".chunk"]),
                                case filelib:is_regular(Chunk) of
                                    true -> ok;
                                    false -> {error, {missing_generated_chunk, Chunk}}
                                end;
                            Other -> {error, {edoc_result, Other}}
                        end
                    catch exit:Reason -> {error, {edoc_exit, Reason}};
                          error:Reason -> {error, {edoc_error, Reason}}
                    after group_leader(OldLeader, self())
                    end
            end;
        _ -> {error, edoc_chunk_tools_unavailable}
    end.

publish_site(Output, Release, Overview, SiteOptions, Docset) ->
    Snapshots = filename:join(Output, "snapshots"),
    case file:make_dir(Snapshots) of
        ok ->
            case 'ldoc-store':put(Snapshots, Docset) of
                ok ->
                    Spec0 = #{release => Release, overview => Overview},
                    Spec1 = optional_map(source_root, maps:get(source_root, SiteOptions), Spec0),
                    Spec = optional_map(source_base, maps:get(source_base, SiteOptions), Spec1),
                    Site = filename:join(Output, "site"),
                    case 'ldoc-site':build(Snapshots, [Spec], Site) of
                        {ok, Index} -> {ok, Index};
                        {error, Reason} -> {error, {stage, site, Output,
                                                   {path, Site, reason, Reason}}}
                    end;
                {error, Reason} -> {error, {stage, store, Output,
                                            {path, Snapshots, reason, Reason}}}
            end;
        {error, Reason} -> {error, {stage, store_directory, Output,
                                    {path, Snapshots, reason, Reason}}}
    end.

optional_map(_Key, undefined, Map) -> Map;
optional_map(Key, Value, Map) -> Map#{Key => Value}.

format_reason(Reason) -> lists:flatten(io_lib:format("~tp", [Reason])).
