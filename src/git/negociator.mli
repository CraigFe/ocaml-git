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

type 'a acks =
  { shallow   : 'a list
  ; unshallow : 'a list
  ; acks      : ('a * [ `Common | `Ready | `Continue | `ACK ]) list }

module type S = sig
  module Store: Minimal.S
  module Decoder: Smart.DECODER with module Hash = Store.Hash

  type state
  type nonrec acks = Store.Hash.t acks

  val find_common: Store.t ->
    (Store.Hash.t list
     * state
     * (acks -> state ->
        ([ `Again of Store.Hash.t list | `Done | `Ready ]* state) Lwt.t)
    ) Lwt.t
end

module Make (G: Minimal.S): S with module Store = G
