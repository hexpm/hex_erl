-module(hex_api_release).
-export([
    delete/3,
    get/3,
    publish/2,
    retire/4,
    unretire/3
]).

%% @doc
%% Gets package release.
%%
%% Examples:
%%
%% ```
%%     hex_api:get_release(<<"package">>, <<"1.0.0">>, hex_core:default_config()).
%%     %%=> {ok, {200, ..., #{
%%     %%=>     <<"version">> => <<"1.0.0">>,
%%     %%=>     <<"meta">> => #{
%%     %%=>         <<"description">> => ...,
%%     %%=>         <<"licenses">> => ...,
%%     %%=>         <<"links">> => ...,
%%     %%=>         <<"maintainers">> => ...
%%     %%=>     },
%%     %%=>     ...}}}
%% '''
%% @end
get(Name, Version, Config) when is_binary(Name) and is_binary(Version) and is_map(Config) ->
    hex_api:get(["packages", Name, "releases", Version], Config).

publish(Tarball, Config) when is_binary(Tarball) and is_map(Config) ->
    TarballContentType = "application/octet-stream",
    Config2 = put_header(<<"content-length">>, integer_to_binary(byte_size(Tarball)), Config),
    Body = {TarballContentType, Tarball},
    hex_api:post(["publish"], Body, Config2).

delete(Name, Version, Config) when is_binary(Name) and is_binary(Version) and is_map(Config) ->
    hex_api:delete(["packages", Name, "releases", Version], Config).

retire(Name, Version, Params, Config) when is_binary(Name) and is_binary(Version) and is_map(Config) ->
    hex_api:post(["packages", Name, "releases", Version, "retire"], Params, Config).

unretire(Name, Version, Config) when is_binary(Name) and is_binary(Version) and is_map(Config) ->
    hex_api:delete(["packages", Name, "releases", Version, "retire"], Config).

%%====================================================================
%% Internal functions
%%====================================================================

put_header(Name, Value, Config) ->
    Headers = maps:get(http_headers, Config, #{}),
    Headers2 = maps:put(Name, Value, Headers),
    maps:put(http_headers, Headers2, Config).
