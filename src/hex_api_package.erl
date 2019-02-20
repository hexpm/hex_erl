-module(hex_api_package).
-export([get/2, search/3]).

%% @doc
%% Gets package.
%%
%% Examples:
%%
%% ```
%% > hex_api_package:get(hex_core:default_config(), <<"package">>).
%% {ok, {200, ..., #{
%%     <<"name">> => <<"package1">>,
%%     <<"meta">> => #{
%%         <<"description">> => ...,
%%         <<"licenses">> => ...,
%%         <<"links">> => ...,
%%         <<"maintainers">> => ...
%%     },
%%     ...,
%%     <<"releases">> => [
%%         #{<<"url">> => ..., <<"version">> => <<"0.5.0">>}],
%%         #{<<"url">> => ..., <<"version">> => <<"1.0.0">>}],
%%         ...
%%     ]}}}
%% '''
%% @end
get(Config, Name) when is_binary(Name) and is_map(Config) ->
    Path = hex_api:build_repository_path(Config, ["packages", Name]),
    hex_api:get(Config, Path).

%% @doc
%% Searches packages.
%%
%% Examples:
%%
%% ```
%% > hex_api_package:search(hex_core:default_config(), <<"package">>, []).
%% {ok, {200, ..., [
%%     #{<<"name">> => <<"package1">>, ...},
%%     ...
%% ]}}
%% '''
search(Config, Query, SearchParams) when is_binary(Query) and is_list(SearchParams) and is_map(Config) ->
    QueryString = hex_api:encode_query_string([{search, Query} | SearchParams]),
    Path = hex_api:join_path_segments(hex_api:build_repository_path(Config, ["packages"])),
    PathQuery = <<Path/binary, "?", QueryString/binary>>,
    hex_api:get(Config, PathQuery).
