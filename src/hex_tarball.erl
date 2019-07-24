-module(hex_tarball).
-export([create/2, create_docs/1, unpack/2, format_checksum/1, format_error/1]).
-ifdef(TEST).
-export([do_decode_metadata/1, gzip/1, normalize_requirements/1]).
-endif.
-define(VERSION, <<"3">>).
-define(TARBALL_MAX_SIZE, 8 * 1024 * 1024).
-define(TARBALL_MAX_UNCOMPRESSED_SIZE, 64 * 1024 * 1024).
-define(BUILD_TOOL_FILES, [
    {<<"mix.exs">>, <<"mix">>},
    {<<"rebar.config">>, <<"rebar3">>},
    {<<"rebar">>, <<"rebar3">>},
    {<<"Makefile">>, <<"make">>},
    {<<"Makefile.win">>, <<"make">>}
]).
-include_lib("kernel/include/file.hrl").

-type checksum() :: binary().
-type contents() :: #{filename() => binary()}.
-type filename() :: string().
-type files() :: [filename() | {filename(), filename()}] | contents().
-type metadata() :: map().
-type tarball() :: binary().

%%====================================================================
%% API functions
%%====================================================================

%% @doc
%% Creates a package tarball.
%%
%% Returns the binary of the tarball the "inner checksum" and "outer checksum".
%% The inner checksum is deprecated in favor of the inner checksum.
%%
%% Examples:
%%
%% ```
%% > Metadata = #{<<"name">> => <<"foo">>, <<"version">> => <<"1.0.0">>},
%% > Files = [{"src/foo.erl", <<"-module(foo).">>}],
%% > {ok, {Tarball, InnerChecksum, OuterChecksum}} = hex_tarball:create(Metadata, Files).
%% > Tarball.
%% <<86,69,...>>
%% > OuterChecksum.
%% <<40,32,...>>
%% '''
%% @end
-spec create(metadata(), files()) -> {ok, {tarball(), checksum()}}.
create(Metadata, Files) ->
    MetadataBinary = encode_metadata(Metadata),
    ContentsTarball = create_memory_tarball(Files),
    ContentsTarballCompressed = gzip(ContentsTarball),
    InnerChecksum = inner_checksum(?VERSION, MetadataBinary, ContentsTarballCompressed),
    InnerChecksumBase16 = encode_base16(InnerChecksum),

    OuterFiles = [
       {"VERSION", ?VERSION},
       {"CHECKSUM", InnerChecksumBase16},
       {"metadata.config", MetadataBinary},
       {"contents.tar.gz", ContentsTarballCompressed}
    ],

    Tarball = create_memory_tarball(OuterFiles),
    OuterChecksum = checksum(Tarball),

    UncompressedSize = byte_size(ContentsTarball),

    case(byte_size(Tarball) > ?TARBALL_MAX_SIZE) or (UncompressedSize > ?TARBALL_MAX_UNCOMPRESSED_SIZE) of
        true ->
            {error, {tarball, too_big}};

        false ->
            {ok, {Tarball, InnerChecksum, OuterChecksum}}
    end.

%% @doc
%% Creates a docs tarball.
%%
%% Examples:
%%
%% ```
%% > Files = [{"doc/index.html", <<"Docs">>}],
%% > {ok, {Tarball, Checksum}} = hex_tarball:create_docs(Files).
%% > Tarball.
%% %%=> <<86,69,...>>
%% > Checksum.
%% %%=> <<40,32,...>>
%% '''
%% @end
-spec create_docs(files()) -> {ok, {tarball(), checksum()}}.
create_docs(Files) ->
    UncompressedTarball = create_memory_tarball(Files),
    UncompressedSize = byte_size(UncompressedTarball),
    Tarball = gzip(UncompressedTarball),
    Size = byte_size(Tarball),

    case(Size > ?TARBALL_MAX_SIZE) or (UncompressedSize > ?TARBALL_MAX_UNCOMPRESSED_SIZE) of
        true ->
            {error, {tarball, too_big}};

        false ->
            {ok, {Tarball, checksum(Tarball)}}
    end.

%% @doc
%% Unpacks a package tarball.
%%
%% Remember to verify the outer tarball checksum against the registry checksum
%% returned from `hex_repo:get_package(Config, Package)`.
%%
%% Examples:
%%
%% ```
%% > hex_tarball:unpack(Tarball, memory).
%% {ok,#{outer_checksum => <<...>>,
%%       contents => [{"src/foo.erl",<<"-module(foo).">>}],
%%       metadata => #{<<"name">> => <<"foo">>, ...}}}
%%
%% > hex_tarball:unpack(Tarball, "path/to/unpack").
%% {ok,#{outer_checksum => <<...>>,
%%       metadata => #{<<"name">> => <<"foo">>, ...}}}
%% '''
-spec unpack(tarball(), memory) ->
                {ok, #{checksum => checksum(), metadata => metadata(), contents => contents()}} |
                {error, term()};
            (tarball(), filename()) ->
                {ok, #{checksum => checksum(), metadata => metadata()}} |
                {error, term()}.
unpack(Tarball, _) when byte_size(Tarball) > ?TARBALL_MAX_SIZE ->
    {error, {tarball, too_big}};

unpack(Tarball, Output) ->
    case hex_erl_tar:extract({binary, Tarball}, [memory]) of
        {ok, []} ->
            {error, {tarball, empty}};

        {ok, FileList} ->
            OuterChecksum = crypto:hash(sha256, Tarball),
            do_unpack(maps:from_list(FileList), OuterChecksum, Output);

        {error, Reason} ->
            {error, {tarball, Reason}}
    end.

%% @doc
%% Returns base16-encoded representation of checksum.
-spec format_checksum(checksum()) -> binary().
format_checksum(Checksum) ->
    encode_base16(Checksum).

%% @doc
%% Converts an error reason term to a human-readable error message string.
-spec format_error(term()) -> string().
format_error({tarball, empty}) -> "empty tarball";
format_error({tarball, too_big}) -> "tarball is too big";
format_error({tarball, {missing_files, Files}}) -> io_lib:format("missing files: ~p", [Files]);
format_error({tarball, {invalid_files, Files}}) -> io_lib:format("invalid files: ~p", [Files]);
format_error({tarball, {bad_version, Vsn}}) -> io_lib:format("unsupported version: ~p", [Vsn]);
format_error({tarball, invalid_checksum}) -> "invalid tarball checksum";
format_error({tarball, Reason}) -> "tarball error, " ++ hex_erl_tar:format_error(Reason);
format_error({inner_tarball, Reason}) -> "inner tarball error, " ++ hex_erl_tar:format_error(Reason);
format_error({metadata, invalid_terms}) -> "error reading package metadata: invalid terms";
format_error({metadata, not_key_value}) -> "error reading package metadata: not in key-value format";
format_error({metadata, Reason}) -> "error reading package metadata" ++ safe_erl_term:format_error(Reason);

format_error({checksum_mismatch, ExpectedChecksum, ActualChecksum}) ->
    io_lib:format(
        "tarball checksum mismatch~n~n" ++
        "Expected (base16-encoded): ~s~n" ++
        "Actual   (base16-encoded): ~s",
        [encode_base16(ExpectedChecksum), encode_base16(ActualChecksum)]).

%%====================================================================
%% Internal functions
%%====================================================================

inner_checksum(Version, MetadataBinary, ContentsBinary) ->
    Blob = <<Version/binary, MetadataBinary/binary, ContentsBinary/binary>>,
    crypto:hash(sha256, Blob).

checksum(ContentsBinary) when is_binary(ContentsBinary) ->
    crypto:hash(sha256, ContentsBinary).

encode_metadata(Meta) ->
    Data = lists:map(
        fun(MetaPair) ->
            String = io_lib_pretty:print(binarify(MetaPair), [{encoding, utf8}]),
            unicode:characters_to_binary([String, ".\n"])
        end, maps:to_list(Meta)),
    iolist_to_binary(Data).

do_unpack(Files, OuterChecksum, Output) ->
    State = #{
        inner_checksum => undefined,
        outer_checksum => OuterChecksum,
        contents => undefined,
        files => Files,
        metadata => undefined,
        output => Output
    },
    State1 = check_files(State),
    State2 = check_version(State1),
    State3 = check_inner_checksum(State2),
    State4 = decode_metadata(State3),
    finish_unpack(State4).

finish_unpack({error, _} = Error) ->
    Error;
finish_unpack(#{metadata := Metadata, files := Files, inner_checksum := InnerChecksum, outer_checksum := OuterChecksum, output := Output}) ->
    _Version = maps:get("VERSION", Files),
    ContentsBinary = maps:get("contents.tar.gz", Files),
    case unpack_tarball(ContentsBinary, Output) of
        ok ->
            copy_metadata_config(Output, maps:get("metadata.config", Files)),
            {ok, #{inner_checksum => InnerChecksum, outer_checksum => OuterChecksum, metadata => Metadata}};

        {ok, Contents} ->
            {ok, #{inner_checksum => InnerChecksum, outer_checksum => OuterChecksum, metadata => Metadata, contents => Contents}};

        {error, Reason} ->
            {error, {inner_tarball, Reason}}
    end.

copy_metadata_config(Output, MetadataBinary) ->
    ok = file:write_file(filename:join(Output, "hex_metadata.config"), MetadataBinary).

check_files(#{files := Files} = State) ->
    RequiredFiles = ["VERSION", "CHECKSUM", "metadata.config", "contents.tar.gz"],
    case diff_keys(Files, RequiredFiles, []) of
        ok ->
            State;

        {error, {missing_keys, Keys}} ->
            {error, {tarball, {missing_files, Keys}}};

        {error, {unknown_keys, Keys}} ->
            {error, {tarball, {invalid_files, Keys}}}
    end.

check_version({error, _} = Error) ->
    Error;
check_version(#{files := Files} = State) ->
    case maps:get("VERSION", Files) of
        <<"3">> ->
            State;

        Version ->
            {error, {tarball, {bad_version, Version}}}
    end.

% Note: This checksum is deprecated
check_inner_checksum({error, _} = Error) ->
    Error;
check_inner_checksum(#{files := Files} = State) ->
    ChecksumBase16 = maps:get("CHECKSUM", Files),
    ExpectedChecksum = decode_base16(ChecksumBase16),

    Version = maps:get("VERSION", Files),
    MetadataBinary = maps:get("metadata.config", Files),
    ContentsBinary = maps:get("contents.tar.gz", Files),
    ActualChecksum = inner_checksum(Version, MetadataBinary, ContentsBinary),

    if
        byte_size(ExpectedChecksum) /= 32 ->
            {error, {tarball, invalid_inner_checksum}};

        ExpectedChecksum == ActualChecksum ->
            maps:put(inner_checksum, ExpectedChecksum, State);

        true ->
            {error, {tarball, {inner_checksum_mismatch, ExpectedChecksum, ActualChecksum}}}
    end.

decode_metadata({error, _} = Error) ->
    Error;
decode_metadata(#{files := #{"metadata.config" := Binary}} = State) when is_binary(Binary) ->
    case do_decode_metadata(Binary) of
        #{} = Metadata -> maps:put(metadata, normalize_metadata(Metadata), State);
        Other -> Other
    end.

do_decode_metadata(Binary) when is_binary(Binary) ->
    {ok, String} = characters_to_list(Binary),

    case safe_erl_term:string(String) of
        {ok, Tokens, _Line} ->
            try
                Terms = safe_erl_term:terms(Tokens),
                maps:from_list(Terms)
            catch
                error:function_clause ->
                    {error, {metadata, invalid_terms}};

                error:badarg ->
                    {error, {metadata, not_key_value}}
            end;

        {error, {_Line, safe_erl_term, Reason}, _Line2} ->
            {error, {metadata, Reason}}
    end.

characters_to_list(Binary) ->
    case unicode:characters_to_list(Binary) of
        List when is_list(List) ->
            {ok, List};
        {error, _, _} ->
            case unicode:characters_to_list(Binary, latin1) of
                List when is_list(List) -> {ok, List};
                Other -> Other
            end
    end.

normalize_metadata(Metadata1) ->
    Metadata2 = maybe_update_with(<<"requirements">>, fun normalize_requirements/1, Metadata1),
    Metadata3 = maybe_update_with(<<"links">>, fun try_into_map/1, Metadata2),
    Metadata4 = maybe_update_with(<<"extra">>, fun try_into_map/1, Metadata3),
    guess_build_tools(Metadata4).

normalize_requirements(Requirements) ->
    case is_list(Requirements) andalso (Requirements /= []) andalso is_list(hd(Requirements)) of
        true ->
            maps:from_list(lists:map(fun normalize_legacy_requirement/1, Requirements));

        false ->
            try_into_map(fun normalize_normal_requirement/1, Requirements)
    end.

normalize_normal_requirement({Name, Requirement}) ->
    {Name, try_into_map(Requirement)}.

normalize_legacy_requirement(Requirement) ->
    Map = maps:from_list(Requirement),
    Name = maps:get(<<"name">>, Map),
    {Name, maps:without([<<"name">>], Map)}.

guess_build_tools(#{<<"build_tools">> := BuildTools} = Metadata) when is_list(BuildTools) ->
    Metadata;
guess_build_tools(#{<<"files">> := Filenames} = Metadata) ->
    BaseFiles = [Filename || Filename <- Filenames, filename:dirname(binary_to_list(Filename)) == "."],
    BuildTools = lists:usort([Tool || {Filename, Tool} <- ?BUILD_TOOL_FILES, lists:member(Filename, BaseFiles)]),
    Metadata#{<<"build_tools">> => BuildTools};
guess_build_tools(Metadata) ->
    Metadata.

%%====================================================================
%% Tar Helpers
%%====================================================================

unpack_tarball(ContentsBinary, memory) ->
    hex_erl_tar:extract({binary, ContentsBinary}, [memory, compressed]);
unpack_tarball(ContentsBinary, Output) ->
    case hex_erl_tar:extract({binary, ContentsBinary}, [{cwd, Output}, compressed]) of
        ok ->
            [try_updating_mtime(filename:join(Output, Path)) || Path <- filelib:wildcard("**", Output)],
            ok;
        Other ->
            Other
    end.

%% let it silently fail for bad symlinks
try_updating_mtime(Path) ->
    Time = calendar:universal_time(),
    _ = file:write_file_info(Path, #file_info{mtime=Time}, [{time, universal}]),
    ok.

create_memory_tarball(Files) ->
    Path = tmp_path(),
    {ok, Tar} = hex_erl_tar:open(Path, [write]),

    try
        add_files(Tar, Files)
    after
        ok = hex_erl_tar:close(Tar)
    end,
    {ok, Tarball} = file:read_file(Path),
    ok = file:delete(Path),
    Tarball.

tmp_path() ->
    "tmp_" ++ binary_to_list(encode_base16(crypto:strong_rand_bytes(32))).

add_files(Tar, Files) when is_list(Files) ->
    lists:map(fun(File) -> add_file(Tar, File) end, Files).

add_file(Tar, {Filename, Contents}) when is_list(Filename) and is_binary(Contents) ->
    ok = hex_erl_tar:add(Tar, Contents, Filename, tar_opts());
add_file(Tar, Filename) when is_list(Filename) ->
    add_file(Tar, {Filename, Filename});
add_file(Tar, {Filename, AbsFilename}) when is_list(Filename), is_list(AbsFilename) ->
    {ok, FileInfo} = file:read_link_info(AbsFilename, []),

    case FileInfo#file_info.type of
        symlink ->
            ok = hex_erl_tar:add(Tar, {Filename, AbsFilename}, tar_opts());
        directory ->
            case file:list_dir(AbsFilename) of
                {ok, []} ->
                    hex_erl_tar:add(Tar, {Filename, AbsFilename}, tar_opts());

                {ok, _} ->
                    ok
            end;
        _ ->
            Mode = FileInfo#file_info.mode,
            {ok, Contents} = file:read_file(AbsFilename),
            ok = hex_erl_tar:add(Tar, Contents, Filename, Mode, tar_opts())
    end.

tar_opts() ->
    NixEpoch = calendar:datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}}),
    Y2kEpoch = calendar:datetime_to_gregorian_seconds({{2000, 1, 1}, {0, 0, 0}}),
    Epoch = Y2kEpoch - NixEpoch,
    [{atime, Epoch}, {mtime, Epoch}, {ctime, Epoch}, {uid, 0}, {gid, 0}].

%% Reproducible gzip by not setting mtime and OS
%%
%% From https://tools.ietf.org/html/rfc1952
%%
%% +---+---+---+---+---+---+---+---+---+---+
%% |ID1|ID2|CM |FLG|     MTIME     |XFL|OS | (more-->)
%% +---+---+---+---+---+---+---+---+---+---+
%%
%% +=======================+
%% |...compressed blocks...| (more-->)
%% +=======================+
%%
%% +---+---+---+---+---+---+---+---+
%% |     CRC32     |     ISIZE     |
%% +---+---+---+---+---+---+---+---+
gzip(Uncompressed) ->
    Compressed = gzip_no_header(Uncompressed),
    Header = <<31, 139, 8, 0, 0, 0, 0, 0, 0, 0>>,
    Crc = erlang:crc32(Uncompressed),
    Size = byte_size(Uncompressed),
    Trailer = <<Crc:32/little, Size:32/little>>,
    iolist_to_binary([Header, Compressed, Trailer]).

gzip_no_header(Uncompressed) ->
    Zstream = zlib:open(),

    try
        zlib:deflateInit(Zstream, default, deflated, -15, 8, default),
        Compressed = zlib:deflate(Zstream, Uncompressed, finish),
        zlib:deflateEnd(Zstream),
        iolist_to_binary(Compressed)
    after
        zlib:close(Zstream)
    end.

%%====================================================================
%% Helpers
%%====================================================================

binarify(Binary) when is_binary(Binary) -> Binary;
binarify(Number) when is_number(Number) -> Number;
binarify(Atom) when Atom == undefined orelse is_boolean(Atom) -> Atom;
binarify(Atom) when is_atom(Atom) -> atom_to_binary(Atom, utf8);
binarify(List) when is_list(List) ->
    [binarify(E) || E <- List];
binarify({Key, Value}) ->
    {binarify(Key), binarify(Value)};
binarify(Map) when is_map(Map) ->
     List = maps:to_list(Map),
     lists:map(fun({K, V}) -> binarify({K, V}) end, List).

diff_keys(Map, RequiredKeys, OptionalKeys) ->
    Keys = maps:keys(Map),
    MissingKeys = RequiredKeys -- Keys,
    UnknownKeys = Keys -- (RequiredKeys ++ OptionalKeys),

    case {MissingKeys, UnknownKeys} of
        {[], []} ->
            ok;

        {_, [_ | _]} ->
            {error, {unknown_keys, UnknownKeys}};

        _ ->
            {error, {missing_keys, MissingKeys}}
    end.

maybe_update_with(Key, Fun, Map) ->
    case maps:find(Key, Map) of
        {ok, Value} -> maps:put(Key, Fun(Value), Map);
        error -> Map
    end.

try_into_map(List) ->
    try_into_map(fun(X) -> X end, List).

try_into_map(Fun, Input) ->
    case is_list(Input) andalso lists:all(fun(E) -> is_tuple(E) andalso (tuple_size(E) == 2) end, Input) of
        true -> maps:from_list(lists:map(Fun, Input));
        false -> Input
    end.

encode_base16(Binary) ->
    <<X:256/big-unsigned-integer>> = Binary,
    String = string:to_upper(lists:flatten(io_lib:format("~64.16.0b", [X]))),
    list_to_binary(String).

%% Based on https://github.com/goj/base16/blob/master/src/base16.erl
%% (C) 2012, Erlang Solutions Ltd.

decode_base16(Base16) ->
    << <<(unhex(H) bsl 4 + unhex(L))>> || <<H,L>> <= Base16 >>.

unhex(D) when $0 =< D andalso D =< $9 ->
    D - $0;
unhex(D) when $a =< D andalso D =< $f ->
    10 + D - $a;
unhex(D) when $A =< D andalso D =< $F ->
    10 + D - $A.
