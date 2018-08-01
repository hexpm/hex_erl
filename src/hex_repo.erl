-module(hex_repo).
-export([
    get_names/1,
    get_versions/1,
    get_package/2,
    get_tarball/3
]).

%%====================================================================
%% API functions
%%====================================================================

%% @doc
%% Gets names resource from the repository.
%%
%% Examples:
%%
%% ```
%%     hex_repo:get_names(hex_erl:default_options()).
%%     %%=> {ok, {200, ...,
%%     %%=>     #{package => [
%%     %%=>         #{name => <<"package1">>},
%%     %%=>         #{name => <<"package2">>},
%%     %%=>     ]}}}
%% '''
%% @end
get_names(Options) when is_list(Options) ->
    Decoder = fun hex_registry:decode_names/1,
    get_protobuf(<<"/names">>, Decoder, Options).

%% @doc
%% Gets versions resource from the repository.
%%
%% Examples:
%%
%% ```
%%     hex_repo:get_versions(Options).
%%     %%=> {ok, {200, ...,
%%     %%=>     #{packages => [
%%     %%=>         #{name => <<"package1">>, retired => [],
%%     %%=>           versions => [<<"1.0.0">>]},
%%     %%=>         #{name => <<"package2">>, retired => [<<"0.5.0>>"],
%%     %%=>           versions => [<<"0.5.0">>, <<"1.0.0">>]},
%%     %%=>     ]}}}
%% '''
%% @end
get_versions(Options) when is_list(Options) ->
    Decoder = fun hex_registry:decode_versions/1,
    get_protobuf(<<"/versions">>, Decoder, Options).

%% @doc
%% Gets package resource from the repository.
%%
%% Examples:
%%
%% ```
%%     hex_repo:get_package(<<"package1">>, hex_erl:default_options()).
%%     %%=> {ok, {200, ...,
%%     %%=>     #{releases => [
%%     %%=>         #{checksum => ..., version => <<"0.5.0">>, dependencies => []},
%%     %%=>         #{checksum => ..., version => <<"1.0.0">>, dependencies => [
%%     %%=>             #{package => <<"package2">>, optional => true, requirement => <<"~> 0.1">>}
%%     %%=>         ]},
%%     %%=>     ]}}}
%% '''
%% @end
get_package(Name, Options) when is_binary(Name) and is_list(Options) ->
    Decoder = fun hex_registry:decode_package/1,
    get_protobuf(<<"/packages/", Name/binary>>, Decoder, Options).

%% @doc
%% Gets tarball from the repository.
%%
%% Examples:
%%
%% ```
%%     {ok, {200, _, Tarball}} = hex_repo:get_tarball(<<"package1">>, <<"1.0.0">>, hex_erl:default_options()),
%%     {ok, #{metadata := Metadata}} = hex_tarball:unpack(Tarball, memory).
%% '''
%% @end
get_tarball(Name, Version, Options) ->
    Client = proplists:get_value(client, Options),
    URI = proplists:get_value(repo_uri, Options),
    ReqHeaders = make_headers(Options),

    case get(Client, tarball_uri(URI, Name, Version), ReqHeaders) of
        {ok, {200, RespHeaders, Tarball}} ->
            {ok, {200, RespHeaders, Tarball}};

        Other ->
            Other
    end.

%%====================================================================
%% Internal functions
%%====================================================================

get(Client, URI, Headers) ->
    hex_http:request(Client, get, URI, Headers).

get_protobuf(Path, Decoder, Options) ->
    Client = proplists:get_value(client, Options),
    URI = proplists:get_value(repo_uri, Options),
    PublicKey = proplists:get_value(repo_public_key, Options),
    ReqHeaders = make_headers(Options),

    case get(Client, <<URI/binary, Path/binary>>, ReqHeaders) of
        {ok, {200, RespHeaders, Compressed}} ->
            Signed = zlib:gunzip(Compressed),
            case decode(Signed, PublicKey, Decoder, Options) of
                {ok, Decoded} ->
                    {ok, {200, RespHeaders, Decoded}};

                {error, _} = Error ->
                    Error
            end;

        Other ->
            Other
    end.

decode(Signed, PublicKey, Decoder, Options) ->
    Verify = proplists:get_value(verify, Options, true),

    case Verify of
        true ->
            case hex_registry:decode_and_verify_signed(Signed, PublicKey) of
                {ok, Payload} ->
                    {ok, Decoder(Payload)};
                Other ->
                    Other
            end;
        false ->
            #{payload := Payload} = hex_registry:decode_signed(Signed),
            {ok, Decoder(Payload)}
    end.

tarball_uri(URI, Name, Version) ->
    Filename = tarball_filename(Name, Version),
    <<URI/binary, "/tarballs/", Filename/binary>>.

tarball_filename(Name, Version) ->
    <<Name/binary, "-", Version/binary, ".tar">>.

make_headers(Options) ->
    lists:foldl(fun set_header/2, #{}, Options).

set_header({etag, ETag}, Headers) -> maps:put(<<"if-none-match">>, ETag, Headers);
set_header({api_key, Token}, Headers) -> maps:put(<<"authorization">>, Token, Headers);
set_header(_Option, Headers) -> Headers.
