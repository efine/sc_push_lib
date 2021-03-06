%%% ==========================================================================
%%% Copyright 2015-2017 Silent Circle
%%%
%%% Licensed under the Apache License, Version 2.0 (the "License");
%%% you may not use this file except in compliance with the License.
%%% You may obtain a copy of the License at
%%%
%%%     http://www.apache.org/licenses/LICENSE-2.0
%%%
%%% Unless required by applicable law or agreed to in writing, software
%%% distributed under the License is distributed on an "AS IS" BASIS,
%%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%% See the License for the specific language governing permissions and
%%% limitations under the License.
%%% ==========================================================================

-module(sc_push_reg_db_mnesia).

-behavior(sc_push_reg_db).

-export([
         db_init/1,
         db_info/1,
         db_terminate/1,
         all_reg/1,
         all_registration_info/1,
         delete_push_regs_by_device_ids/2,
         delete_push_regs_by_ids/2,
         delete_push_regs_by_svc_toks/2,
         delete_push_regs_by_tags/2,
         update_invalid_timestamps_by_svc_toks/2,
         get_registration_info_by_device_id/2,
         get_registration_info_by_id/2,
         get_registration_info_by_svc_tok/2,
         get_registration_info_by_tag/2,
         is_valid_push_reg/2,
         reregister_ids/2,
         reregister_svc_toks/2,
         save_push_regs/2
        ]).

-include("sc_push_lib.hrl").
-include_lib("stdlib/include/ms_transform.hrl").

%% FIXME: May want to choose sync_transaction because cluster may
%% extend across data centers, and
%% - If 2nd phase commit fails and
%% - Network to DC is down, and
%% - Async transaction is used
%% Then this transaction may quietly be reversed when connectivity is restored,
%% even after it's told the caller it succeeded.
%% OTOH, it's much much slower. So we'll leave it as a compile-time option.

-ifdef(SC_MNESIA_SYNC_TRANSACTIONS).
-define(TXN2(Txn, Args), mnesia:sync_transaction(Txn, Args)).
-else.
-define(TXN2(Txn, Args), mnesia:transaction(Txn, Args)).
-endif.

-define(SPRDB, sc_push_reg_db).

%%--------------------------------------------------------------------
%% Records
%%--------------------------------------------------------------------
% id is a globally unique identifier that is used to identify
% an app/device/user combination anonymously.
-record(sc_pshrg, {
        id = {<<>>, <<>>} :: sc_push_reg_db:reg_id_key(),
        device_id = <<>> :: sc_push_reg_db:device_id(),
        tag = <<>> :: sc_push_reg_db:tag(), % User identification tag, e.g. <<"user@server">>
        svc_tok = {undefined, <<>>} :: sc_push_reg_db:svc_tok_key(),
        app_id = <<>> :: sc_push_reg_db:app_id(), % iOS AppBundleID, Android package
        dist = <<>> :: sc_push_reg_db:dist(), % distribution <<>> is same as <<"prod">>, or <<"dev">>
        modified = {0, 0, 0} :: sc_push_reg_db:mod_time(),
        last_invalid_on = undefined :: sc_push_reg_db:inv_time(),
        created_on = os:timestamp() :: sc_push_reg_db:created_on()
    }).

-type push_reg_list() :: list(#sc_pshrg{}).
-type ctx() :: term().

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% @doc Initialize the database connection.
%%
%% Return an opaque context for use with db_info/1 and db_terminate/1.
%%
%% <dl>
%% <dt>`Context'</dt><dd>An opaque term returned to the caller.</dd>
%% <dt>`Config :: [node()]'</dt>
%% <dd>A list of atoms (nodes) on which to create the Mnesia tables. If the
%% list is empty, defaults to a list containing only the current `node()'.
%% This has only been tested with a current node. It is not recommended to use
%% Mnesia in a distributed context for push registrations due to issues arising
%% from network partitions (split-brain).</dd>
%% </dl>
%% @end
%%--------------------------------------------------------------------
-spec db_init(Config) -> {ok, Context} | {error, Reason} when
      Config :: map() | proplists:proplist(), Context :: ctx(),
      Reason :: term().
db_init(Config) when is_map(Config) ->
    db_init(maps:get(connection, Config));
db_init(Config) when is_list(Config) ->
    Nodes = sc_util:val(nodes, Config, [node()]),
    Ctx = [],
    case application:get_env(mnesia, dir) of
        {ok, Dir} ->
            lager:debug("Mnesia dir: ~s", [Dir]),
            ok = filelib:ensure_dir(Dir),
            mnesia:start(),
            create_tables(Ctx, Nodes),
            {ok, Ctx};
        undefined ->
            {error, "-mnesia dir \"path/to/db\" "
                    "missing from environment"}
    end.

%%--------------------------------------------------------------------
%% @doc Get information about the database context passed in `Ctx'.
%%
%% This is currently a no-op and returns an empty list.
%% @end
%%--------------------------------------------------------------------
-spec db_info(Ctx) -> Props when
      Ctx :: ctx(), Props :: proplists:proplist().
db_info(_Ctx) -> [].

%%--------------------------------------------------------------------
%% @doc Terminate the database connection.
%% This is a no-op an the return value has no significance.
%% @end
%%--------------------------------------------------------------------
-spec db_terminate(ctx()) -> ok.
db_terminate(_Ctx) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @deprecated For debug only.
%% @doc Return a list of property lists of all push registration records.
%% @end
%%--------------------------------------------------------------------
-spec all_registration_info(ctx()) -> sc_push_reg_db:mult_reg_db_props().
all_registration_info(Ctx) ->
    [sc_pshrg_to_props(R) || R <- all_reg(Ctx)].

%%--------------------------------------------------------------------
%% @private
%% @deprecated For debug only.
%% @doc Return a list of all push registration records.
%% @end
%%--------------------------------------------------------------------
-spec all_reg(ctx()) -> list().
all_reg(_Ctx) ->
    do_txn(fun() ->
                mnesia:select(sc_pshrg, ets:fun2ms(fun(R) -> R end))
        end).

%%--------------------------------------------------------------------
create_tables(_Ctx, Nodes) ->
    Defs = [
        {sc_pshrg,
            [
                {disc_copies, Nodes},
                {type, set},
                {index, [#sc_pshrg.device_id, #sc_pshrg.tag, #sc_pshrg.svc_tok]},
                {attributes, record_info(fields, sc_pshrg)}
            ]
        }
    ],

    [create_table(Tab, Attrs) || {Tab, Attrs} <- Defs],
    upgrade_tables().

%%--------------------------------------------------------------------
%% @doc Delete push registrations by device ids
-spec delete_push_regs_by_device_ids(ctx(), [binary()]) ->
    ok | {error, term()}.
delete_push_regs_by_device_ids(_Ctx, DeviceIDs) when is_list(DeviceIDs) ->
    do_txn(delete_push_regs_by_device_id_txn(), [DeviceIDs]).

%%--------------------------------------------------------------------
%% @doc Delete push registrations by internal registration id.
-spec delete_push_regs_by_ids(ctx(), sc_push_reg_db:reg_id_keys()) ->
    ok | {error, term()}.
delete_push_regs_by_ids(_Ctx, IDs) ->
    do_txn(delete_push_regs_txn(), [IDs]).

%%--------------------------------------------------------------------
%% @doc Delete push registrations by service-token.
-spec delete_push_regs_by_svc_toks(ctx(), [sc_push_reg_db:svc_tok_key()]) ->
    ok | {error, term()}.
delete_push_regs_by_svc_toks(_Ctx, SvcToks) when is_list(SvcToks) ->
    do_txn(delete_push_regs_by_svc_tok_txn(), [SvcToks]).

%%--------------------------------------------------------------------
%% @doc Delete push registrations by tags.
-spec delete_push_regs_by_tags(ctx(), [binary()]) -> ok | {error, term()}.
delete_push_regs_by_tags(_Ctx, Tags) when is_list(Tags) ->
    do_txn(delete_push_regs_by_tag_txn(), [Tags]).

%%--------------------------------------------------------------------
%% @doc Update push registration last_invalid timestamp by service-token.
-spec update_invalid_timestamps_by_svc_toks(ctx(),
                                            [{sc_push_reg_db:svc_tok_key(),
                                              non_neg_integer()}]) ->
    ok | {error, term()}.
update_invalid_timestamps_by_svc_toks(_Ctx, SvcToksTs)
  when is_list(SvcToksTs) ->
    do_txn(update_invalid_timestamps_by_svc_toks_txn(), [SvcToksTs]).

%%--------------------------------------------------------------------
%% @doc Get registration information by device id.
-spec get_registration_info_by_device_id(ctx(), binary()) ->
    sc_push_reg_db:mult_reg_db_props() | notfound.
get_registration_info_by_device_id(_Ctx, DeviceID) ->
    get_registration_info_impl(DeviceID, fun lookup_reg_device_id/1).

%%--------------------------------------------------------------------
%% @doc Get registration information by unique id.
%% @see sc_push_reg_api:make_id/2
-spec get_registration_info_by_id(ctx(), sc_push_reg_db:reg_id_key()) ->
    sc_push_reg_db:mult_reg_db_props() | notfound.
get_registration_info_by_id(_Ctx, ID) ->
    get_registration_info_impl(ID, fun lookup_reg_id/1).

%%--------------------------------------------------------------------
%% @doc Get registration information by service-token.
%% @see sc_push_reg_api:make_svc_tok/2
-spec get_registration_info_by_svc_tok(ctx(), sc_push_reg_db:svc_tok_key()) ->
    sc_push_reg_db:mult_reg_db_props() | notfound.
get_registration_info_by_svc_tok(_Ctx, {_Service, _Token} = SvcTok) ->
    get_registration_info_impl(SvcTok, fun lookup_svc_tok/1).

%%--------------------------------------------------------------------
%% @doc Get registration information by tag.
-spec get_registration_info_by_tag(ctx(), binary()) ->
    sc_push_reg_db:mult_reg_db_props() | notfound.
get_registration_info_by_tag(_Ctx, Tag) ->
    get_registration_info_impl(Tag, fun lookup_reg_tag/1).

%%--------------------------------------------------------------------
%% @doc Is push registration proplist valid?
-spec is_valid_push_reg(ctx(), sc_types:proplist(atom(), term())) -> boolean().
is_valid_push_reg(_Ctx, PL) ->
    try make_sc_pshrg(PL) of
        _ -> true
    catch _:_ -> false
    end.

%%--------------------------------------------------------------------
%% @doc Save a list of push registrations.
-spec save_push_regs(ctx(), [sc_push_reg_db:reg_db_props(), ...]) ->
    ok | {error, term()}.
save_push_regs(_Ctx, ListOfProplists) ->
    Regs = [make_sc_pshrg(PL) || PL <- ListOfProplists],
    do_txn(save_push_regs_txn(), [Regs]).

%%--------------------------------------------------------------------
%% @doc Re-register invalidated tokens
-spec reregister_ids(ctx(), [{sc_push_reg_db:reg_id_key(), binary()}]) -> ok.
reregister_ids(_Ctx, IDToks) when is_list(IDToks) ->
    do_txn(reregister_ids_txn(), [IDToks]).

%%--------------------------------------------------------------------
%% @doc Re-register invalidated tokens by svc_tok
-spec reregister_svc_toks(ctx(), [{sc_push_reg_db:svc_tok_key(),
                                   binary()}]) -> ok.
reregister_svc_toks(_Ctx, SvcToks) when is_list(SvcToks) ->
    do_txn(reregister_svc_toks_txn(), [SvcToks]).

%%====================================================================
%% Internal functions
%%====================================================================
make_sc_pshrg([_|_] = Props)  ->
    ServiceS = sc_util:to_list(sc_util:val(service, Props, "apns")),
    Service = sc_util:to_atom(sc_util:req_s(ServiceS)),
    Token = sc_util:req_val(token, Props),
    DeviceId = sc_util:req_val(device_id, Props),
    Tag = sc_util:val(tag, Props, ""),
    AppId = sc_util:req_val(app_id, Props),
    Dist = sc_util:val(dist, Props, ""),
    make_sc_pshrg(Service, Token, DeviceId, Tag, AppId, Dist).

%%--------------------------------------------------------------------
-spec make_sc_pshrg(Service, Token, DeviceId, Tag, AppId, Dist) -> Result when
      Service :: sc_push_reg_db:atom_or_str(),
      Token :: sc_push_reg_db:binable(),
      DeviceId :: sc_push_reg_db:binable(),
      Tag :: sc_push_reg_db:binable(),
      AppId :: sc_push_reg_db:binable(),
      Dist :: sc_push_reg_db:binable(),
      Result :: #sc_pshrg{}.
make_sc_pshrg(Service, Token, DeviceId, Tag, AppId, Dist) ->
    Modified = os:timestamp(),
    LastInvalidOn = undefined,
    CreatedOn = Modified,
    make_sc_pshrg(Service, Token, DeviceId, Tag, AppId, Dist, Modified,
                 LastInvalidOn, CreatedOn).

%%--------------------------------------------------------------------
-spec make_sc_pshrg(Service, Token, DeviceId, Tag, AppId, Dist, Modified,
                    LastInvalidOn, CreatedOn) -> Result when
      Service :: sc_push_reg_db:atom_or_str(),
      Token :: sc_push_reg_db:binable(),
      DeviceId :: sc_push_reg_db:binable(),
      Tag :: sc_push_reg_db:binable(),
      AppId :: sc_push_reg_db:binable(),
      Dist :: sc_push_reg_db:binable(),
      Modified :: erlang:timestamp(),
      LastInvalidOn :: undefined | erlang:timestamp(),
      CreatedOn :: erlang:timestamp(),
      Result :: #sc_pshrg{}.
make_sc_pshrg(Service, Token, DeviceId, Tag, AppId, Dist, Modified,
              LastInvalidOn, CreatedOn) ->
    #sc_pshrg{
        id = sc_push_reg_api:make_id(DeviceId, Tag),
        device_id = DeviceId,
        tag = sc_util:to_bin(Tag),
        svc_tok = sc_push_reg_api:make_svc_tok(Service, Token),
        app_id = sc_util:to_bin(AppId),
        dist = sc_util:to_bin(Dist),
        created_on = CreatedOn,
        modified = Modified,
        last_invalid_on = LastInvalidOn
    }.
%%--------------------------------------------------------------------
sc_pshrg_to_props(#sc_pshrg{svc_tok = SvcToken,
                            tag = Tag,
                            device_id = DeviceID,
                            app_id = AppId,
                            dist = Dist,
                            created_on = CreatedOn,
                            modified = Modified,
                            last_invalid_on = LastInvalidOn}) ->
    {Service, Token} = SvcToken,
    ?SPRDB:make_sc_push_props(Service, Token, DeviceID, Tag,
                              AppId, Dist, Modified, LastInvalidOn,
                              CreatedOn).

%%--------------------------------------------------------------------
%% Database functions
%%--------------------------------------------------------------------
create_table(Tab, Attrs) ->
    Res = mnesia:create_table(Tab, Attrs),

    case Res of
        {atomic, ok} -> ok;
        {aborted, {already_exists, _}} -> ok;
        _ ->
            throw({create_table_error, Res})
    end.

%%--------------------------------------------------------------------
upgrade_tables() ->
    upgrade_sc_pshrg().

%%--------------------------------------------------------------------
upgrade_sc_pshrg() ->
    Res = case mnesia:table_info(sc_pshrg, attributes) of
              [id, device_id, tag, svc_tok, app_id, dist, modified,
               last_invalid_on, created_on] ->
                  ok; % Latest version
              [id, device_id, tag, svc_tok, app_id, dist, version, modified] ->
                  fun({sc_pshrg, _Id, DeviceId, Tag, {Svc, Tok}, AppId, Dist,
                       _Version, Modified}) ->
                          LastInvalidOn = undefined,
                          CreatedOn = Modified,
                          make_sc_pshrg(Svc, Tok, DeviceId, Tag, AppId, Dist,
                                        Modified, LastInvalidOn, CreatedOn)
                  end;
              _ -> % Leave alone
                  ok
          end,
    maybe_transform_tables(Res).

%%--------------------------------------------------------------------
maybe_transform_tables(ok) ->
    ok;
maybe_transform_tables(Xform) when is_function(Xform, 1) ->
    % Transform table (will transform all replicas of the table
    % on other nodes, too, and if they are running the old code,
    % the process will crash when the table is upgraded.
    ok = mnesia:wait_for_tables([sc_pshrg], 30000),
    NewAttrs = record_info(fields, sc_pshrg),
    ok = delete_all_table_indexes(sc_pshrg),
    {atomic, ok} = mnesia:transform_table(sc_pshrg, Xform, NewAttrs),
    _ = add_table_indexes(sc_pshrg, [device_id, tag, svc_tok]).

%%--------------------------------------------------------------------
delete_all_table_indexes(Tab) ->
    _ = [{atomic, ok} = mnesia:del_table_index(Tab, N)
         || N <- mnesia:table_info(Tab, index)],
    ok.

%%--------------------------------------------------------------------
add_table_indexes(Tab, Attrs) ->
    [
        case mnesia:add_table_index(Tab, Attr) of
            {aborted,{already_exists, _, _}} ->
                ok;
            {atomic, ok} ->
                ok
        end || Attr <- Attrs
    ].

%%--------------------------------------------------------------------
-spec lookup_reg_id(sc_push_reg_db:reg_id_key()) -> push_reg_list().
lookup_reg_id(ID) ->
    do_txn(fun() -> mnesia:read(sc_pshrg, ID) end).

%%--------------------------------------------------------------------
-spec lookup_reg_device_id(binary()) -> push_reg_list().
lookup_reg_device_id(DeviceID) when is_binary(DeviceID) ->
    do_txn(fun() ->
                mnesia:index_read(sc_pshrg, DeviceID, #sc_pshrg.device_id)
        end).

%%--------------------------------------------------------------------
-spec lookup_reg_tag(binary()) -> push_reg_list().
lookup_reg_tag(Tag) when is_binary(Tag) ->
    do_txn(fun() ->
                mnesia:index_read(sc_pshrg, Tag, #sc_pshrg.tag)
        end).

%%--------------------------------------------------------------------
-spec lookup_svc_tok(sc_push_reg_db:svc_tok_key()) -> push_reg_list().
lookup_svc_tok({Service, Token} = SvcTok) when is_atom(Service),
                                               is_binary(Token) ->
    do_txn(fun() ->
                mnesia:index_read(sc_pshrg, SvcTok, #sc_pshrg.svc_tok)
        end).

%%--------------------------------------------------------------------
-spec save_push_regs_txn() -> fun((push_reg_list()) -> ok).
save_push_regs_txn() ->
    fun(PushRegs) ->
            [write_rec(R) || R <- PushRegs],
            ok
    end.

%%--------------------------------------------------------------------
-spec delete_push_regs_txn() -> fun(([binary()]) -> ok).
delete_push_regs_txn() ->
    fun(IDs) ->
            _ = [mnesia:delete({sc_pshrg, ID}) || ID <- IDs],
            ok
    end.

%%--------------------------------------------------------------------
-spec delete_push_regs_by_tag_txn() -> fun(([binary()]) -> ok).
delete_push_regs_by_tag_txn() ->
    delete_push_regs_by_index_txn(#sc_pshrg.tag).

%%--------------------------------------------------------------------
-spec delete_push_regs_by_device_id_txn() -> fun(([binary()]) -> ok).
delete_push_regs_by_device_id_txn() ->
    delete_push_regs_by_index_txn(#sc_pshrg.device_id).

%%--------------------------------------------------------------------
-spec delete_push_regs_by_svc_tok_txn() ->
    fun(([sc_push_reg_db:svc_tok_key()]) -> ok).
delete_push_regs_by_svc_tok_txn() ->
    delete_push_regs_by_index_txn(#sc_pshrg.svc_tok).

%%--------------------------------------------------------------------
-spec delete_push_regs_by_index_txn(non_neg_integer()) ->
    fun(([term()]) -> ok).
delete_push_regs_by_index_txn(Index) ->
    fun(Keys) ->
            [delete_push_reg_by_index(Key, Index) || Key <- Keys],
            ok
    end.

%%--------------------------------------------------------------------
-spec update_invalid_timestamps_by_svc_toks_txn() ->
    fun(([{sc_push_reg_db:svc_tok_key(), non_neg_integer()}]) -> ok).
update_invalid_timestamps_by_svc_toks_txn() ->
    fun(SvcToksTs) when is_list(SvcToksTs) ->
        [ok = update_invalid_timestamps_by_index(SvcTokTs, #sc_pshrg.svc_tok)
         || SvcTokTs <- SvcToksTs],
        ok
    end.

%%--------------------------------------------------------------------
%% MUST be called in txn
-spec delete_push_reg_by_index(term(), non_neg_integer()) -> ok.
delete_push_reg_by_index(Key, Index) ->
    case mnesia:index_read(sc_pshrg, Key, Index) of
        [] ->
            ok;
        Recs ->
            _ = [mnesia:delete({sc_pshrg, R#sc_pshrg.id}) || R <- Recs],
            ok
    end.

%%--------------------------------------------------------------------
%% MUST be called in txn
-spec update_invalid_timestamps_by_index(term(), non_neg_integer()) -> ok.
update_invalid_timestamps_by_index({Key, TimestampMs}, Index) ->
    case mnesia:index_read(sc_pshrg, Key, Index) of
        [] ->
            ok;
        Recs ->
            ErlTimestamp = sc_push_reg_db:from_posix_time_ms(TimestampMs),
            [write_rec(R#sc_pshrg{last_invalid_on=ErlTimestamp}) || R <- Recs],
            ok
    end.

%%--------------------------------------------------------------------
-spec reregister_ids_txn() ->
    fun(([{sc_push_reg_db:reg_id_key(), binary()}]) -> ok).
reregister_ids_txn() ->
    fun(IDToks) ->
            [reregister_one_id(ID, NewTok) || {ID, NewTok} <- IDToks],
            ok
    end.

%%--------------------------------------------------------------------
%% MUST be called in a transaction
reregister_one_id(ID, NewTok) ->
    case mnesia:read(sc_pshrg, ID, write) of
        [#sc_pshrg{svc_tok = {Svc, _}} = R] ->
            R1 = R#sc_pshrg{svc_tok = sc_push_reg_api:make_svc_tok(Svc, NewTok)},
            write_rec(R1);
        [] -> % Does not exist, so that's fine
            ok
    end.

%%--------------------------------------------------------------------
-spec reregister_svc_toks_txn() ->
    fun(([{sc_push_reg_db:svc_tok_key(), binary()}]) -> ok).
reregister_svc_toks_txn() ->
    fun(SvcToks) ->
            [reregister_svc_toks_impl(SvcTok, NewTok) || {SvcTok, NewTok} <- SvcToks],
            ok
    end.

%%--------------------------------------------------------------------
%% MUST be called in a transaction
%% Legacy records: if token == device_id, change device_id as well.
reregister_svc_toks_impl(OldSvcTok, NewTok) ->
    case mnesia:index_read(sc_pshrg, OldSvcTok, #sc_pshrg.svc_tok) of
        [] -> % Does not exist, so that's fine
            ok;
        [_|_] = Rs ->
            [ok = reregister_one_svc_tok(NewTok, R) || R <- Rs],
            ok
    end.

%%--------------------------------------------------------------------
%% MUST be called in a transaction
reregister_one_svc_tok(NewTok, #sc_pshrg{svc_tok = {Svc, OldTok}} = R0) ->
    NewSvcTok = sc_push_reg_api:make_svc_tok(Svc, NewTok),
    % If old token same as old device ID, change device ID too
    % for legacy records
    R1 = case R0#sc_pshrg.id of
        {OldDeviceId, OldTag} when OldDeviceId =:= OldTok ->
            delete_rec(R0), % Delete old rec
            R0#sc_pshrg{id = sc_push_reg_api:make_id(NewTok, OldTag),
                        device_id = NewTok,
                        svc_tok = NewSvcTok};
        _ ->
            R0#sc_pshrg{svc_tok = NewSvcTok}
    end,
    write_rec(R1).

%%--------------------------------------------------------------------
%% MUST be called in a transaction.
-compile({inline, [{write_rec, 1}]}).
write_rec(#sc_pshrg{} = R) ->
    ok = mnesia:write(R).

%%--------------------------------------------------------------------
%% MUST be called in a transaction.
-compile({inline, [{delete_rec, 1}]}).
delete_rec(#sc_pshrg{} = R) ->
    ok = mnesia:delete_object(R).

%%--------------------------------------------------------------------
-compile({inline, [{do_txn, 2}]}).
-spec do_txn(fun(), list()) -> Result::term().
do_txn(Txn, Args) ->
    {atomic, Result} = ?TXN2(Txn, Args),
    Result.

%%--------------------------------------------------------------------
-compile({inline, [{do_txn, 1}]}).
-spec do_txn(fun()) -> Result::term().
do_txn(Txn) ->
    do_txn(Txn, []).

%%--------------------------------------------------------------------
%% MUST be in transaction
get_registration_info_impl(Key, DBLookup) when is_function(DBLookup, 1) ->
    case DBLookup(Key) of
        [#sc_pshrg{}|_] = Regs ->
            [sc_pshrg_to_props(Reg) || Reg <- Regs];
        [] ->
            notfound
    end.

