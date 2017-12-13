(*
 * Copyright (c) 2013-2017 Thomas Gazagnaire <thomas@gazagnaire.org>
 * and Romain Calascibetta <romain.calascibetta@gmail.com>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

open Lwt.Infix
let ( >>!= ) = Lwt_result.bind_lwt_err
let ( >>?= ) = Lwt_result.bind

let src = Logs.Src.create "git.sync" ~doc:"logs git's sync event"
module Log = (val Logs.src_log src: Logs.LOG)

module Option = struct
  let mem v x ~equal = match v with Some x' -> equal x x' | None -> false
end

module Default = struct
  let capabilities =
    [ `Multi_ack_detailed
    ; `Thin_pack
    ; `Side_band_64k
    ; `Ofs_delta
    ; `Agent "git/2.0.0"
    ; `Report_status
    ; `No_done ]
end

module type NET = sig
  type socket
  val read  : socket -> Bytes.t -> int -> int -> int Lwt.t
  val write : socket -> Bytes.t -> int -> int -> int Lwt.t
  val socket: Uri.t -> socket Lwt.t
  val close : socket -> unit Lwt.t
end

module type S = sig

  module Store: Minimal.S
  module Net: NET
  module Client: Smart.CLIENT with module Hash = Store.Hash

  type error =
    [ `SmartPack of string
    | `Pack      of Store.Pack.error
    | `Clone     of string
    | `Fetch     of string
    | `Ls        of string
    | `Push      of string
    | `Ref       of Store.Ref.error
    | `Not_found ]

  val pp_error: error Fmt.t

  type command =
    [ `Create of (Store.Hash.t * Store.Reference.t)
    | `Delete of (Store.Hash.t * Store.Reference.t)
    | `Update of (Store.Hash.t * Store.Hash.t * Store.Reference.t) ]

  val push:
    Store.t
    -> push:((Store.Hash.t * string * bool) list -> (Store.Hash.t list * command list) Lwt.t)
    -> ?capabilities:Capability.t list
    -> Uri.t
    -> ((string, string * string) result list, error) result Lwt.t

  val ls:
    Store.t
    -> ?capabilities:Capability.t list
    -> Uri.t
    -> ((Store.Hash.t * string * bool) list, error) result Lwt.t

  val fetch_ext:
    Store.t
    -> ?shallow:Store.Hash.t list
    -> ?capabilities:Capability.t list
    -> notify:(Client.Decoder.shallow_update -> unit Lwt.t)
    -> negociate:((Client.Decoder.acks -> 'state -> ([ `Ready | `Done | `Again of Store.Hash.t list ] * 'state) Lwt.t) * 'state)
    -> has:Store.Hash.t list
    -> want:((Store.Hash.t * string * bool) list -> (Store.Reference.t * Store.Hash.t) list Lwt.t)
    -> ?deepen:[ `Depth of int | `Timestamp of int64 | `Ref of string ]
    -> Uri.t
    -> ((Store.Reference.t * Store.Hash.t) list * int, error) result Lwt.t

  val clone_ext:
    Store.t
    -> ?reference:Store.Reference.t
    -> ?capabilities:Capability.t list
    -> Uri.t
    -> (Store.Hash.t, error) result Lwt.t

  val fetch_some:
    Store.t -> ?locks:Store.Lock.t ->
    ?capabilities:Capability.t list ->
    references:Store.Reference.t list Store.Reference.Map.t ->
    Uri.t -> (Store.Hash.t Store.Reference.Map.t
              * Store.Reference.t list Store.Reference.Map.t, error) result Lwt.t

  val fetch_all:
    Store.t -> ?locks:Store.Lock.t ->
    ?capabilities:Capability.t list ->
    references:Store.Reference.t list Store.Reference.Map.t ->
    Uri.t -> (Store.Hash.t Store.Reference.Map.t
              * Store.Reference.t list Store.Reference.Map.t
              * Store.Hash.t Store.Reference.Map.t, error) result Lwt.t

  val fetch_one:
    Store.t -> ?locks:Store.Lock.t ->
    ?capabilities:Capability.t list ->
    reference:(Store.Reference.t * Store.Reference.t list) ->
    Uri.t -> ([ `AlreadySync | `Sync of Store.Hash.t Store.Reference.Map.t ], error) result Lwt.t

  val clone:
    Store.t -> ?locks:Store.Lock.t ->
    ?capabilities:Capability.t list ->
    reference:(Store.Reference.t * Store.Reference.t) ->
    Uri.t -> (unit, error) result Lwt.t

  val update_and_create: Store.t ->
    ?capabilities:Capability.t list ->
    references:Store.Reference.t list Store.Reference.Map.t ->
    Uri.t -> ((Store.Reference.t, Store.Reference.t * string) result list, error) result Lwt.t
end

module Common
    (G: Minimal.S)
= struct
  module Store = G
  module Revision = Revision.Make(Store)

  module Log =
  struct
    let src = Logs.Src.create "git.common.sync" ~doc:"logs git's common sync event"
    include (val Logs.src_log src: Logs.LOG)
  end

  open Lwt.Infix

  let packer ?(window = `Object 10) ?(depth = 50) git ~ofs_delta:_ remote commands =
    let commands' =
      (List.map (fun (hash, refname, _) -> `Delete (hash, refname)) remote)
      @ commands
    in

    (* XXX(dinosaure): we don't want to delete remote references but
       we want to exclude any commit already stored remotely. Se, we «
       delete » remote references from the result set. *)

    Lwt_list.fold_left_s (fun acc -> function
        | `Create _ -> Lwt.return acc
        | `Update (hash, _, _) ->
          Revision.(Range.normalize git (Range.Include (from_hash hash)))
          >|= Store.Hash.Set.union acc
        | `Delete (hash, _) ->
          Revision.(Range.normalize git (Range.Include (from_hash hash)))
          >|= Store.Hash.Set.union acc
      ) Store.Hash.Set.empty commands'
    >>= fun negative ->
    Lwt_list.fold_left_s (fun acc -> function
        | `Create (hash, _) ->
          Revision.(Range.normalize git (Range.Include (from_hash hash)))
          >|= Store.Hash.Set.union acc
        | `Update (_, hash, _) ->
          Revision.(Range.normalize git (Range.Include (from_hash hash)))
          >|= Store.Hash.Set.union acc
        | `Delete _ -> Lwt.return acc
      ) Store.Hash.Set.empty commands
    >|= (fun positive -> Revision.Range.E.diff positive negative)
    >>= fun elements ->
    Lwt_list.fold_left_s (fun acc commit ->
        Store.fold git
          (fun acc ?name:_ ~length:_ _ value -> Lwt.return (value :: acc))
          ~path:(Fpath.v "/") acc commit
      ) [] (Store.Hash.Set.elements elements)
    >>= fun entries -> Store.Pack.make git ~window ~depth entries

  let want_handler git choose remote_refs =
    (* XXX(dinosaure): in this /engine/, for each remote references,
       we took or not only if this reference is not /peeled/. Then,
       [choose] returns [true] or [false] if he wants to download the
       reference or not. Finally, we check if we don't have already
       the remote hash. and if it's the case, we don't download it. *)
    Lwt_list.filter_map_s (function
        | (remote_hash, remote_ref, false) ->
          (choose remote_ref >>= function
            | false ->
              Log.debug (fun l -> l ~header:"want_handler" "We missed the reference %a."
                            Store.Reference.pp remote_ref);
              Lwt.return None
            | true ->
              Lwt.return (Some (remote_ref, remote_hash)))
          >>= (function
              | None -> Lwt.return None
              | Some (remote_ref, remote_hash) ->
                Store.mem git remote_hash >>= function
                | true -> Lwt.return None
                | false -> Lwt.return (Some (remote_ref, remote_hash)))
        | _ -> Lwt.return None)
      remote_refs

  exception Jump of Store.Ref.error

  let update_and_create git ?locks ~references results =
    let results = List.fold_left
        (fun results (remote_ref, hash) -> Store.Reference.Map.add remote_ref hash results)
        Store.Reference.Map.empty results in
    let updated, missed = Store.Reference.Map.partition
        (fun remote_ref _ -> Store.Reference.Map.mem remote_ref results)
        references in
    let updated, downloaded = Store.Reference.Map.fold
        (fun remote_ref new_hash (updated', downloaded) ->
           try
             let local_refs = Store.Reference.Map.find remote_ref updated in
             List.fold_left (fun updated' local_ref -> Store.Reference.Map.add local_ref new_hash updated')
               updated' local_refs, downloaded
           with Not_found -> updated', Store.Reference.Map.add remote_ref new_hash downloaded)
        results Store.Reference.Map.(empty, empty) in
    Lwt.try_bind
      (fun () ->
         Lwt_list.iter_s
           (fun (local_ref, new_hash) ->
              Store.Ref.write git ?locks local_ref (Store.Reference.Hash new_hash)
              >>= function
              | Ok _ -> Lwt.return ()
              | Error err -> Lwt.fail (Jump err))
           (Store.Reference.Map.bindings updated))
      (fun () -> Lwt.return (Ok (updated, missed, downloaded)))
      (function
        | Jump err -> Lwt.return (Error (`Ref err))
        | exn -> Lwt.fail exn)

  let push_handler git references remote_refs =
    Store.Ref.list git >>= fun local_refs ->
    let local_refs = List.fold_left
        (fun local_refs (local_ref, local_hash) ->
           Store.Reference.Map.add local_ref local_hash local_refs)
        Store.Reference.Map.empty local_refs in

    Lwt_list.filter_map_p (function
        | (remote_hash, remote_ref, false) -> Lwt.return (Some (remote_ref, remote_hash))
        | _ -> Lwt.return None)
      remote_refs
    >>= fun remote_refs ->
    let actions =
      Store.Reference.Map.fold
        (fun local_ref local_hash actions ->
           try let remote_refs' = Store.Reference.Map.find local_ref references in
             List.fold_left (fun actions remote_ref ->
                 try let remote_hash = List.assoc remote_ref remote_refs in
                   `Update (remote_hash, local_hash, remote_ref) :: actions
                 with Not_found -> `Create (local_hash, remote_ref) :: actions)
               actions remote_refs'
            with Not_found -> actions)
        local_refs []
    in

    Lwt_list.filter_map_s
      (fun action -> match action with
        | `Update (remote_hash, local_hash, _) ->
          Store.mem git remote_hash >>= fun has_remote_hash ->
          Store.mem git local_hash >>= fun has_local_hash ->

          if has_remote_hash && has_local_hash
          then Lwt.return (Some action)
          else Lwt.return None
        | `Create (local_hash, _) ->
          Store.mem git local_hash >>= function
          | true -> Lwt.return (Some action)
          | false -> Lwt.return None)
      actions
end

module Make (N: NET) (S: Minimal.S) = struct

  module Store = S
  module Net= N

  module Client = Smart.Client(Store.Hash)
  module Hash = Store.Hash
  module Inflate = Store.Inflate
  module Deflate = Store.Deflate
  module Revision = Revision.Make(Store)
  module PACKEncoder = Pack.MakePACKEncoder(Hash)(Deflate)

  type error =
    [ `SmartPack of string
    | `Pack      of Store.Pack.error
    | `Clone     of string
    | `Fetch     of string
    | `Ls        of string
    | `Push      of string
    | `Ref       of S.Ref.error
    | `Not_found ]

  let pp_error ppf = function
    | `SmartPack err -> Helper.ppe ~name:"`SmartPack" Fmt.string ppf err
    | `Pack err       -> Helper.ppe ~name:"`Pack" Store.Pack.pp_error ppf err
    | `Clone err      -> Helper.ppe ~name:"`Clone" Fmt.string ppf err
    | `Fetch err      -> Helper.ppe ~name:"`Fetch" Fmt.string ppf err
    | `Push err       -> Helper.ppe ~name:"`Push" Fmt.string ppf err
    | `Ls err         -> Helper.ppe ~name:"`Ls" Fmt.string ppf err
    | `Ref err        -> Helper.ppe ~name:"`Ref" S.Ref.pp_error ppf err
    | `Not_found      -> Fmt.string ppf "`Not_found"

  type command =
    [ `Create of (Store.Hash.t * Store.Reference.t)
    | `Delete of (Store.Hash.t * Store.Reference.t)
    | `Update of (Store.Hash.t * Store.Hash.t * Store.Reference.t) ]

  type t =
    { socket: Net.socket
    ; input : Bytes.t
    ; output: Bytes.t
    ; ctx   : Client.context
    ; capabilities: Capability.t list }

  let err_unexpected_result result =
    let buf = Buffer.create 64 in
    let ppf = Fmt.with_buffer buf in

    Fmt.pf ppf "Unexpected result: %a%!" (Fmt.hvbox Client.pp_result) result;
    Buffer.contents buf

  let rec process t result =
    match result with
    | `Read (buffer, off, len, continue) ->
      Net.read t.socket t.input 0 len >>= fun len ->
      Cstruct.blit_from_bytes t.input 0 buffer off len;
      process t (continue len)
    | `Write (buffer, off, len, continue) ->
      Cstruct.blit_to_bytes buffer off t.output 0 len;
      Net.write t.socket t.output 0 len >>= fun n ->
      process t (continue n)
    | `Error (err, buf, committed) ->
      let raw = Cstruct.sub buf committed (Cstruct.len buf - committed) in
      Log.err (fun l -> l ~header:"process" "Retrieve an error (%a) on: %a."
                  Client.Decoder.pp_error err
                  (Fmt.hvbox (Minienc.pp_scalar ~get:Cstruct.get_char ~length:Cstruct.len)) raw);
      assert false (* TODO *)
    | #Client.result as result ->
      Lwt.return result

  module Common
    : module type of Common(Store)
      with module Store = Store
    = Common(Store)

  module Pack = struct
    let default_stdout raw =
      Log.info (fun l -> l ~header:"populate:stdout" "%S" (Cstruct.to_string raw));
      Lwt.return ()

    let default_stderr raw =
      Log.err (fun l -> l ~header:"populate:stderr" "%S" (Cstruct.to_string raw));
      Lwt.return ()

    let populate git ?(stdout = default_stdout) ?(stderr = default_stderr) ctx first =
      let stream, push = Lwt_stream.create () in

      let cstruct_copy cs =
        let ln = Cstruct.len cs in
        let rs = Cstruct.create ln in
        Cstruct.blit cs 0 rs 0 ln;
        rs
      in

      let rec dispatch ctx = function
        | `PACK (`Out raw) ->
          stdout raw >>= fun () ->
          Client.run ctx.ctx `ReceivePACK |> process ctx >>= dispatch ctx
        | `PACK (`Err raw) ->
          stderr raw >>= fun () ->
          Client.run ctx.ctx `ReceivePACK |> process ctx >>= dispatch ctx
        | `PACK (`Raw raw) ->
          push (Some (cstruct_copy raw));
          Client.run ctx.ctx `ReceivePACK |> process ctx >>= dispatch ctx
        | `PACK `End ->
          push None;
          Lwt.return (Ok ())
        | result -> Lwt.return (Error (`SmartPack (err_unexpected_result result)))
      in

      dispatch ctx first
      >>?= fun ()  -> Store.Pack.from git (fun () -> Lwt_stream.get stream)
      >>!= fun err -> Lwt.return (`Pack err)
  end

  let rec clone_handler git reference t r =
    match r with
    | `Negociation _ ->
      Client.run t.ctx `Done
      |> process t
      >>= clone_handler git reference t
    | `NegociationResult _ ->
      Client.run t.ctx `ReceivePACK
      |> process t
      >>= Pack.populate git t
      >>= (function
          | Ok (hash, _) -> Lwt.return (Ok hash)
          | Error _ as err -> Lwt.return err)
    | `ShallowUpdate _ ->
      Client.run t.ctx (`Has []) |> process t
      >>= clone_handler git reference t
    | `Refs refs ->
      (try
         let (hash_head, _, _) =
           List.find
             (fun (_, refname, peeled) -> Store.Reference.(equal reference (of_string refname)) && not peeled)
             refs.Client.Decoder.refs
         in
         Client.run t.ctx (`UploadRequest { Client.Encoder.want = hash_head, [ hash_head ]
                                          ; capabilities = t.capabilities
                                          ; shallow = []
                                          ; deep = None })
         |> process t
         >>= clone_handler git reference t
       with Not_found ->
         Client.run t.ctx `Flush
         |> process t
         >>= function `Flush -> Lwt.return (Error `Not_found)
                    | result -> Lwt.return (Error (`Clone (err_unexpected_result result))))
    | result -> Lwt.return (Error (`Clone (err_unexpected_result result)))

  let ls_handler _ t r =
    match r with
    | `Refs refs ->
      Client.run t.ctx `Flush
      |> process t
      >>= (function `Flush -> Lwt.return (Ok refs.Client.Decoder.refs)
                  | result -> Lwt.return (Error (`Ls (err_unexpected_result result))))
    | result -> Lwt.return (Error (`Ls (err_unexpected_result result)))

  let fetch_handler git ?(shallow = []) ~notify ~negociate:(fn, state) ~has ~want ?deepen t r =
    let pack asked t =
      Client.run t.ctx `ReceivePACK
      |> process t
      >>= Pack.populate git t
      >>= function
      | Ok (_, n) -> Lwt.return (Ok (asked, n))
      | Error err -> Lwt.return (Error err)
    in

    let rec aux t asked state = function
      | `ShallowUpdate shallow_update ->
        notify shallow_update >>= fun () ->
        Client.run t.ctx (`Has has) |> process t >>= aux t asked state
      | `Negociation acks ->
        Log.debug (fun l -> l ~header:"fetch_handler" "Retrieve the negotiation: %a."
                      (Fmt.hvbox Client.Decoder.pp_acks) acks);

        fn acks state >>=
        (function
          | `Ready, _ ->
            Log.debug (fun l -> l ~header:"fetch_handler" "Retrieve `Ready ACK from negotiation engine.");
            Client.run t.ctx `Done |> process t >>= aux t asked state
          | `Done, state ->
            Log.debug (fun l -> l ~header:"fetch_handler" "Retrieve `Done ACK from negotiation engine.");
            Client.run t.ctx `Done |> process t >>= aux t asked state
          | `Again has, state ->
            Log.debug (fun l -> l ~header:"fetch_handler" "Retrieve `Again ACK from negotiation engine.");
            Client.run t.ctx (`Has has) |> process t >>= aux t asked state)
      | `NegociationResult _ ->
        Log.debug (fun l -> l ~header:"fetch_handler" "Retrieve a negotiation result.");
        pack asked t
      | `Refs refs ->
        want refs.Client.Decoder.refs >>=
        (function
          | first :: rest ->
            Client.run t.ctx
              (`UploadRequest { Client.Encoder.want = snd first, List.map snd rest
                              ; capabilities = t.capabilities
                              ; shallow
                              ; deep = deepen })
            |> process t
            >>= aux t (first :: rest) state
          | [] -> Client.run t.ctx `Flush
                  |> process t
            >>= (function `Flush -> Lwt.return (Ok ([], 0))
                        (* XXX(dinosaure): better return? *)
                        | result -> Lwt.return (Error (`Fetch (err_unexpected_result result)))))
      | result -> Lwt.return (Error (`Ls (err_unexpected_result result)))
    in

    aux t [] state r

  let push_handler git ~push t r =
    let send_pack stream t r =
      let rec go ?keep t r =
        let consume ?keep dst =
          match keep with
          | Some keep ->
            let n = min (Cstruct.len keep) (Cstruct.len dst) in
            Cstruct.blit keep 0 dst 0 n;
            let keep = Cstruct.shift keep n in
            if Cstruct.len keep > 0
            then Lwt.return (`Continue (Some keep, n))
            else Lwt.return (`Continue (None, n))
          | None ->
            stream () >>= function
            | Some keep ->
              let n = min (Cstruct.len keep) (Cstruct.len dst) in
              Cstruct.blit keep 0 dst 0 n;
              let keep = Cstruct.shift keep n in
              if Cstruct.len keep > 0
              then Lwt.return (`Continue (Some keep, n))
              else Lwt.return (`Continue (None, n))
            | None -> Lwt.return `Finish
        in

        match r with
        | `ReadyPACK dst ->
          (consume ?keep dst >>= function
            | `Continue (keep, n) ->
              Client.run t.ctx (`SendPACK n)
              |> process t
              >>= go ?keep t
            | `Finish ->
              Client.run t.ctx `FinishPACK
              |> process t
              >>= go t)
        | `Nothing -> Lwt.return (Ok [])
        | `ReportStatus { Client.Decoder.unpack = Ok (); commands; } ->
          Lwt.return (Ok commands)
        | `ReportStatus { Client.Decoder.unpack = Error err; _ } ->
          Lwt.return (Error (`Push err))
        | result -> Lwt.return (Error (`Push (err_unexpected_result result)))
      in

      go t r
    in

    let rec aux t refs commands = function
      | `Refs refs ->
        Log.debug (fun l -> l ~header:"push_handler" "Receiving reference: %a."
                      (Fmt.hvbox Client.Decoder.pp_advertised_refs) refs);
        let capabilities =
          List.filter (function
              | `Report_status | `Delete_refs | `Ofs_delta | `Push_options
              | `Agent _ | `Side_band | `Side_band_64k -> true
              | _ -> false
            ) t.capabilities
        in

        (push refs.Client.Decoder.refs >>= function
          | (_,  []) ->
            Client.run t.ctx `Flush
            |> process t
            >|= (function
                | `Flush -> Ok []
                | result -> Error (`Push (err_unexpected_result result)))
          | (shallow, commands) ->
            Lwt_list.map_s
              (function
                | `Create (hash, reference) -> Lwt.return (`Create (hash, Store.Reference.to_string reference))
                | `Delete (hash, reference) -> Lwt.return (`Delete (hash, Store.Reference.to_string reference))
                | `Update (a, b, reference) -> Lwt.return (`Update (a, b, Store.Reference.to_string reference)))
              commands >>= fun commands ->
            Log.debug (fun l ->
                let pp_command ppf = function
                  | `Create (hash, refname) ->
                    Fmt.pf ppf "(`Create (%a, %s))" S.Hash.pp hash refname
                  | `Delete (hash, refname) ->
                    Fmt.pf ppf "(`Delete (%a, %s))" S.Hash.pp hash refname
                  | `Update (_of, _to, refname) ->
                    Fmt.pf ppf "(`Update (of:%a, to:%a, %s))"
                      S.Hash.pp _of S.Hash.pp _to refname
                in
                l ~header:"push_handler" "Sending command(s): %a."
                  (Fmt.hvbox (Fmt.Dump.list pp_command)) commands
              );
            let x, r =
              List.map (function
                  | `Create (hash, r) -> Client.Encoder.Create (hash, r)
                  | `Delete (hash, r) -> Client.Encoder.Delete (hash, r)
                  | `Update (_of, _to, r) -> Client.Encoder.Update (_of, _to, r)
                )commands
              |> fun commands -> List.hd commands, List.tl commands
            in

            Client.run t.ctx (`UpdateRequest { Client.Encoder.shallow
                                             ; requests = Client.Encoder.L (x, r)
                                             ; capabilities })
            |> process t
            >>= aux t (Some refs.Client.Decoder.refs) (Some (x :: r)))
      | `ReadyPACK _ as result ->
        Log.debug (fun l ->
            l ~header:"push_handler" "The server is ready to receive the PACK \
                                      file.");
        let ofs_delta = List.exists ((=) `Ofs_delta) (Client.capabilities t.ctx) in
        let commands = match commands with Some commands -> commands | None -> assert false in
        let refs     = match refs with Some refs -> refs | None -> assert false in

        (* XXX(dinosaure): in this case, we can use GADT to describe the
           protocol by the session-type (like, [`UpdateRequest] makes a
           [`] response). So, we can constraint some assertions about
           the context when we catch [`ReadyPACK].

           One of this assertion is about the [commands] variable, which one is
           previously specified. So, the [None] value can not be catch and it's
           why we have an [assert false]. *)

        Lwt_list.map_p
          (function
            | Client.Encoder.Create (hash, refname) -> Lwt.return (`Create (hash, refname))
            | Client.Encoder.Delete (hash, refname) -> Lwt.return (`Delete (hash, refname))
            | Client.Encoder.Update (a, b, refname) -> Lwt.return (`Update (a, b, refname)))
          commands
        >>= Common.packer git ~ofs_delta refs >>= (function
            | Ok (stream, _) ->
              send_pack stream t result
            | Error err -> Lwt.return (Error (`Pack err)))
      | result -> Lwt.return (Error (`Push (err_unexpected_result result)))
    in

    aux t None None r

  let port uri = match Uri.port uri with
    | None   -> 9418
    | Some p -> p

  let host uri = match Uri.host uri with
    | Some h -> h
    | None   ->
      Fmt.kstrf failwith "Expected a git url with host: %a." Uri.pp_hum uri

  let path uri = Uri.path_and_query uri

  module N = Negociator.Make(S)

  let push git ~push ?(capabilities=Default.capabilities) uri =
    Log.debug (fun l -> l "push %a" Uri.pp_hum uri);
    Net.socket uri >>= fun socket ->
    let ctx, state = Client.context { Client.Encoder.pathname = path uri
                                    ; host = Some (host uri, Some (port uri))
                                    ; request_command = `ReceivePack }
    in
    let t = { socket
            ; input = Bytes.create 65535
            ; output = Bytes.create 65535
            ; ctx
            ; capabilities }
    in
    Log.debug (fun l -> l ~header:"push" "Start to process the flow");
    process t state
    >>= push_handler git ~push t
    >>= fun v -> Net.close socket
    >>= fun () -> Lwt.return v

  let ls git ?(capabilities=Default.capabilities) uri =
    Log.debug (fun l -> l "ls %a" Uri.pp_hum uri);
    Net.socket uri >>= fun socket ->
    let ctx, state = Client.context { Client.Encoder.pathname = path uri
                                    ; host = Some (host uri, Some (port uri))
                                    ; request_command = `UploadPack }
    in
    let t = { socket
            ; input = Bytes.create 65535
            ; output = Bytes.create 65535
            ; ctx
            ; capabilities }
    in
    Log.debug (fun l -> l ~header:"ls" "Start to process the flow.");

    process t state
    >>= ls_handler git t
    >>= fun v -> Net.close socket
    >>= fun () -> Lwt.return v

  let fetch_ext git ?(shallow = []) ?(capabilities=Default.capabilities)
      ~notify ~negociate ~has ~want ?deepen uri =
    Log.debug (fun l -> l "fetch_ext %a" Uri.pp_hum uri);
    Net.socket uri >>= fun socket ->
    let ctx, state = Client.context { Client.Encoder.pathname = path uri
                                    ; host = Some (host uri, Some (port uri))
                                    ; request_command = `UploadPack }
    in
    let t = { socket
            ; input = Bytes.create 65535
            ; output = Bytes.create 65535
            ; ctx
            ; capabilities }
    in
    Log.debug (fun l -> l ~header:"fetch" "Start to process the flow.");

    process t state
    >>= fetch_handler git ~shallow ~notify ~negociate ~has ~want ?deepen t
    >>= fun v -> Net.close socket
    >>= fun () -> Lwt.return v

  let clone_ext git
      ?(reference = Store.Reference.master)
      ?(capabilities=Default.capabilities) uri =
    Log.debug (fun l -> l "clone_ext %a" Uri.pp_hum uri);
    Net.socket uri >>= fun socket ->
    let ctx, state = Client.context { Client.Encoder.pathname = path uri
                                    ; host = Some (host uri, Some (port uri))
                                    ; request_command = `UploadPack }
    in
    let t = { socket
            ; input = Bytes.create 65535
            ; output = Bytes.create 65535
            ; ctx
            ; capabilities }
    in
    Log.debug (fun l -> l ~header:"clone" "Start to process the flow.");

    process t state
    >>= clone_handler git reference t
    >>= fun v -> Net.close socket
    >>= fun () -> Lwt.return v

  let fetch_and_set_references git ?locks ?capabilities ~choose ~references repository =
    N.find_common git >>= fun (has, state, continue) ->
    let continue { Client.Decoder.acks; shallow; unshallow } state =
      continue { Negociator.acks; shallow; unshallow } state in
    let want_handler refs =
      Lwt_list.map_p
        (fun (hash, refname, peeled) ->
           Lwt.return (hash, Store.Reference.of_string refname, peeled))
        refs >>= Common.want_handler git choose in
    fetch_ext git ?capabilities ~notify:(fun _ -> Lwt.return ())
      ~negociate:(continue, state) ~has ~want:want_handler
      repository
    >>?= fun (results, _) ->
    Common.update_and_create git ?locks ~references results

  let fetch_all git ?locks ?capabilities ~references repository =
    let choose _ = Lwt.return true in
    fetch_and_set_references
      ~choose
      ?locks
      ?capabilities
      ~references
      git repository

  let fetch_some git ?locks ?capabilities ~references repository =
    let choose remote_ref =
      Lwt.return (Store.Reference.Map.mem remote_ref references) in
    fetch_and_set_references
      ~choose
      ?locks
      ?capabilities
      ~references
      git repository
    >>?= fun (updated, missed, downloaded) ->
    if Store.Reference.Map.is_empty downloaded
    then Lwt.return (Ok (updated, missed))
    else begin
      Log.err (fun l -> l ~header:"fetch_some" "This case should not appear, we download: %a."
                  Fmt.Dump.(list (pair Store.Reference.pp Store.Hash.pp))
                  (Store.Reference.Map.bindings downloaded));

      Lwt.return (Ok (updated, missed))
    end

  let fetch_one git ?locks ?capabilities ~reference:(remote_ref, local_refs) repository =
    let references = Store.Reference.Map.singleton remote_ref local_refs in
    let choose remote_ref =
      Lwt.return (Store.Reference.Map.mem remote_ref references) in
    fetch_and_set_references
      ~choose
      ?locks
      ?capabilities
      ~references
      git repository
    >>?= fun (updated, missed, downloaded) ->
    if not (Store.Reference.Map.is_empty downloaded)
    then Log.err (fun l -> l ~header:"fetch_some" "This case should not appear, we downloaded: %a."
                     Fmt.Dump.(list (pair Store.Reference.pp Store.Hash.pp))
                     (Store.Reference.Map.bindings downloaded));

    match Store.Reference.Map.(bindings updated, bindings missed) with
    | [], [ _ ] -> Lwt.return (Ok `AlreadySync)
    | _ :: _, [] -> Lwt.return (Ok (`Sync updated))
    | [], missed ->
      Log.err
        (fun l -> l ~header:"fetch_one" "This case should not appear, we missed too many references: %a."
            Fmt.Dump.(list (pair Store.Reference.pp (list Store.Reference.pp)))
            missed);
      Lwt.return (Ok `AlreadySync)
    | _ :: _, missed ->
      Log.err
        (fun l -> l ~header:"fetch_one" "This case should not appear, we missed too many references: %a."
            Fmt.Dump.(list (pair Store.Reference.pp (list Store.Reference.pp)))
            missed);
      Lwt.return (Ok (`Sync updated))

  let clone t ?locks ?capabilities ~reference:(remote_ref, local_ref) uri =
    Log.debug (fun l -> l "clone %a:%a" Uri.pp_hum uri S.Reference.pp remote_ref);
    let _ =
      if not (Option.mem (Uri.scheme uri) "git" ~equal:String.equal)
      then raise (Invalid_argument "Expected a git url");
    in
    clone_ext t ?capabilities ~reference:remote_ref uri >>?= function
    | hash' ->
      Log.debug (fun l ->
          l ~header:"easy_clone" "Update reference %a to %a."
            S.Reference.pp local_ref S.Hash.pp hash');

      S.Ref.write t ?locks local_ref (S.Reference.Hash hash')
      >>!= (fun err -> Lwt.return (`Ref err))
      >>?= fun () -> S.Ref.write t ?locks S.Reference.head (S.Reference.Ref local_ref)
      >>!= fun err -> Lwt.return (`Ref err)

  let update_and_create git ?capabilities ~references repository =
    let push_handler remote_refs =
      Lwt_list.map_p
        (fun (hash, refname, peeled) -> Lwt.return (hash, Store.Reference.of_string refname, peeled))
        remote_refs
      >>= Common.push_handler git references
      >>= fun actions -> Lwt.return ([], actions) in
    push git ~push:push_handler ?capabilities repository
    >>?= fun lst ->
    Lwt_result.ok (Lwt_list.map_p (function
        | Ok refname -> Lwt.return (Ok (Store.Reference.of_string refname))
        | Error (refname, err) ->
          Lwt.return (Error (Store.Reference.of_string refname, err))
      ) lst)
end
