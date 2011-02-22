(*****************************************************************************

  Liquidsoap, a programmable audio stream generator.
  Copyright 2003-2010 Savonet team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details, fully stated in the COPYING
  file at the root of the liquidsoap distribution.

  You should have received a copy of the GNU General Public License
  along with this program; if not, write to the Free Software
  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

 *****************************************************************************)
(** Output to an harbor server. *)
module Icecast =
  struct
    type protocol = unit
    
    let protocol_of_icecast_protocol _ = ()
      
    type content = string
    
    let format_of_content x = x
      
    type info = unit
    
    let info_of_encoder _ = ()
      
  end
  
module M = Icecast_utils.Icecast_v(Icecast)
  
open M
  
(* Max total length for ICY metadata is 255*16 
 * Format is: "StreamTitle='%s';StreamUrl='%s'" 
 * "StreamTitle='';"; is 15 chars long, "StreamUrl='';"
 * is 13 chars long, leaving 4052 chars remaining. 
 * Splitting those in: 
 * * max title length = 3852
 * * max url length = 200 *)
let max_title = 3852
  
let max_url = 200
  
let proto kind =
  Output.proto @
    [ ("mount", Lang.string_t, None, None);
      ("protocol", Lang.string_t, (Some (Lang.string "http")),
       (Some
          "Protocol of the streaming server: \
           'http' for Icecast, 'icy' for shoutcast."));
      ("port", Lang.int_t, (Some (Lang.int 8000)), None);
      ("user", Lang.string_t, (Some (Lang.string "")),
       (Some "User for client connection, disabled if empty."));
      ("password", Lang.string_t, (Some (Lang.string "hackme")), None);
      ("url", Lang.string_t, (Some (Lang.string "")), None);
      ("metaint", Lang.int_t, (Some (Lang.int 16000)),
       (Some "Interval \
    used to send ICY metadata"));
      ("encoding", Lang.string_t, (Some (Lang.string "")),
       (Some "Encoding used to send metadata, default (UTF-8) if empty."));
      ("auth",
       (Lang.fun_t [ (false, "", Lang.string_t); (false, "", Lang.string_t) ]
          Lang.bool_t),
       (Some
          (Lang.val_cst_fun
             [ ("", Lang.string_t, None); ("", Lang.string_t, None) ]
             (Lang.bool false))),
       (Some
          "Authentication function. \
            <code>f(login,password)</code> returns <code>true</code> \
            if the user should be granted access for this login. \
            Override any other method if used."));
      ("buffer", Lang.int_t, (Some (Lang.int (5 * 65535))),
       (Some "Maximun buffer per-client."));
      ("burst", Lang.int_t, (Some (Lang.int 65534)),
       (Some "Initial burst of data sent to the client."));
      ("chunk", Lang.int_t, (Some (Lang.int 1024)),
       (Some
          "Send data to clients using chunks of at \
          least this length."));
      ("on_connect",
       (Lang.fun_t
          [ (false, "headers", Lang.metadata_t);
            (false, "uri", Lang.string_t);
            (false, "protocol", Lang.string_t); (false, "", Lang.string_t) ]
          Lang.unit_t),
       (Some
          (Lang.val_cst_fun
             [ ("headers", Lang.metadata_t, None);
               ("uri", Lang.string_t, None);
               ("protocol", Lang.string_t, None); ("", Lang.string_t, None) ]
             Lang.unit)),
       (Some "Callback executed when connection is established."));
      ("on_disconnect",
       (Lang.fun_t [ (false, "", Lang.string_t) ] Lang.unit_t),
       (Some (Lang.val_cst_fun [ ("", Lang.string_t, None) ] Lang.unit)),
       (Some "Callback executed when connection stops."));
      ("headers", Lang.metadata_t,
       (Some (Lang.list (Lang.product_t Lang.string_t Lang.string_t) [])),
       (Some "Additional headers."));
      ("icy_metadata", Lang.string_t, (Some (Lang.string "guess")),
       (Some
          "Send new metadata using the ICY protocol. \
          One of: \"guess\", \"true\", \"false\""));
      ("format", Lang.string_t, (Some (Lang.string "")),
       (Some
          "Format, e.g. \"audio/ogg\". \
           When empty, the encoder is used to guess."));
      ("dumpfile", Lang.string_t, (Some (Lang.string "")),
       (Some "Dump stream to file, for debugging purpose. Disabled if empty."));
      ("", (Lang.format_t kind), None, (Some "Encoding format."));
      ("", (Lang.source_t kind), None, None) ]
  
type client_state = | Hello | Sending | Done

type metadata =
  { mutable metadata : Frame.metadata option; metadata_m : Mutex.t
  }

type client =
  { mutable buffer : Buffer.t; condition : Duppy.Monad.Condition.condition;
    condition_m : Duppy.Monad.Mutex.mutex; mutex : Mutex.t; meta : metadata;
    mutable latest_meta : string; metaint : int; url : string option;
    mutable metapos : int; chunk : int; mutable state : client_state;
    close : unit -> unit;
    handler : (Tutils.priority, Harbor.reply) Duppy.Monad.Io.handler
  }

let add_meta c data =
  let get_meta meta =
    let f x =
      try Some (Hashtbl.find (Utils.get_some meta) x)
      with | Not_found -> None in
    let meta_info =
      match ((f "artist"), (f "title")) with
      | (Some a, Some t) -> Some (Printf.sprintf "%s - %s" a t)
      | (Some s, None) | (None, Some s) -> Some s
      | (None, None) -> None in
    let meta =
      match meta_info with
      | Some s when (String.length s) > max_title ->
          Printf.sprintf "StreamTitle='%s...';"
            (String.sub s 0 (max_title - 3))
      | Some s -> Printf.sprintf "StreamTitle='%s';" s
      | None -> "" in
    let meta =
      match c.url with
      | Some s when (String.length s) > max_url ->
          Printf.sprintf "%sStreamURL='%s...';" meta
            (String.sub s 0 (max_url - 3))
      | Some s -> Printf.sprintf "%sStreamURL='%s';" meta s
      | None -> meta in
    (* Pad string to a multiple of 16 bytes. *)
    let len = String.length meta in
    let pad = (len / 16) + 1 in
    let ret = String.make ((pad * 16) + 1) ' '
    in
      (ret.[0] <- Char.chr pad;
       String.blit meta 0 ret 1 len;
       if ret <> c.latest_meta then (c.latest_meta <- ret; ret) else "\000") in
  let rec process meta rem data =
    let pos = c.metaint - c.metapos in
    let before = String.sub data 0 pos in
    let after = String.sub data pos ((String.length data) - pos)
    in
      if (String.length after) > c.metaint
      then
        (let rem = Printf.sprintf "%s%s%s" rem before meta
         in (c.metapos <- 0; process "\000" rem after))
      else
        (c.metapos <- String.length after;
         Printf.sprintf "%s%s%s%s" rem before meta after)
  in
    if c.metaint > 0
    then
      if ((String.length data) + c.metapos) > c.metaint
      then
        (let meta =
           Tutils.mutexify c.meta.metadata_m (fun () -> c.meta.metadata) ()
         in process (get_meta meta) "" data)
      else (c.metapos <- c.metapos + (String.length data); data)
    else data
  
let rec client_task c =
  let __pa_duppy_0 =
    Duppy.Monad.Io.exec ~priority: Tutils.Maybe_blocking c.handler
      (Tutils.mutexify c.mutex
         (fun () ->
            let buflen = Buffer.length c.buffer in
            let data =
              if buflen > c.chunk
              then
                (let data = Some (add_meta c (Buffer.contents c.buffer))
                 in (Buffer.reset c.buffer; data))
              else None
            in Duppy.Monad.return data)
         ())
  in
    Duppy.Monad.bind __pa_duppy_0
      (fun data ->
         Duppy.Monad.bind
           (match data with
            | None ->
                Duppy.Monad.bind (Duppy.Monad.Mutex.lock c.condition_m)
                  (fun () ->
                     Duppy.Monad.bind
                       (Duppy.Monad.Condition.wait c.condition c.condition_m)
                       (fun () -> Duppy.Monad.Mutex.unlock c.condition_m))
            | Some s ->
                Duppy.Monad.Io.write ~priority: Tutils.Non_blocking c.handler
                  s)
           (fun () ->
              let __pa_duppy_0 =
                Duppy.Monad.Io.exec ~priority: Tutils.Maybe_blocking
                  c.handler
                  (let ret = Tutils.mutexify c.mutex (fun () -> c.state) ()
                   in Duppy.Monad.return ret)
              in
                Duppy.Monad.bind __pa_duppy_0
                  (fun state ->
                     if state <> Done
                     then client_task c
                     else Duppy.Monad.return ())))
  
let client_task c =
  (Tutils.mutexify c.mutex
     (fun () -> (assert (c.state = Hello); c.state <- Sending)) ();
   Duppy.Monad.catch (client_task c) (fun _ -> Duppy.Monad.raise ()))
  
(** Sending encoded data to a shout-compatible server.
  * It directly takes the Lang param list and extracts stuff from it. *)
class output ~kind p =
  let e f v = f (List.assoc v p)
  in let s v = e Lang.to_string v
    in let on_connect = List.assoc "on_connect" p
      in let on_disconnect = List.assoc "on_disconnect" p
        in
          let on_connect ~headers ~protocol ~uri s =
            ignore
              (Lang.apply ~t: Lang.unit_t on_connect
                 [ ("headers", (Lang.metadata headers));
                   ("uri", (Lang.string uri));
                   ("protocol", (Lang.string protocol));
                   ("", (Lang.string s)) ])
          in
            let on_disconnect s =
              ignore
                (Lang.apply ~t: Lang.unit_t on_disconnect
                   [ ("", (Lang.string s)) ])
            in let metaint = Lang.to_int (List.assoc "metaint" p)
              in
                let (_, encoder_factory, format, icecast_info, icy_metadata,
                     ogg, out_enc) =
                  encoder_data p
                in let buflen = Lang.to_int (List.assoc "buffer" p)
                  in let burst = Lang.to_int (List.assoc "burst" p)
                    in let chunk = Lang.to_int (List.assoc "chunk" p)
                      in
                        let () =
                          (if chunk > buflen
                           then
                             raise
                               (Lang.Invalid_value (List.assoc "buffer" p,
                                  "Maximum buffering inferior to chunk length"))
                           else ();
                           if burst > buflen
                           then
                             raise
                               (Lang.Invalid_value (List.assoc "buffer" p,
                                  "Maximum buffering inferior to burst length"))
                           else ())
                        in let source = Lang.assoc "" 2 p
                          in let mount = s "mount"
                            in
                              let uri =
                                match mount.[0] with
                                | '/' -> mount
                                | _ -> Printf.sprintf "%c%s" '/' mount
                              in
                                let autostart =
                                  Lang.to_bool (List.assoc "start" p)
                                in
                                  let infallible =
                                    not
                                      (Lang.to_bool (List.assoc "fallible" p))
                                  in
                                    let on_start =
                                      let f = List.assoc "on_start" p
                                      in
                                        fun () ->
                                          ignore
                                            (Lang.apply ~t: Lang.unit_t f [])
                                    in
                                      let on_stop =
                                        let f = List.assoc "on_stop" p
                                        in
                                          fun () ->
                                            ignore
                                              (Lang.apply ~t: Lang.unit_t f
                                                 [])
                                      in
                                        let url =
                                          match s "url" with
                                          | "" -> None
                                          | x -> Some x
                                        in let port = e Lang.to_int "port"
                                          in let default_user = s "user"
                                            in
                                              let default_password =
                                                s "password"
                                              in
                                                (* Cf sources/harbor_input.ml *)
                                                let trivially_false =
                                                  function
                                                  | {
                                                      Lang.value =
                                                        Lang.Fun (_, _, _,
                                                          {
                                                            Lang_values.
                                                              term =
                                                              Lang_values.
                                                                Bool false
                                                          })
                                                      } -> true
                                                  | _ -> false
                                                in
                                                  let auth_function =
                                                    List.assoc "auth" p
                                                  in
                                                    let login user password =
                                                      let (user, password) 
                                                        =
                                                        let f = Configure.
                                                          recode_tag
                                                        in
                                                          ((f user),
                                                           (f password)) in
                                                      let default_login 
                                                        =
                                                        (user = default_user)
                                                          &&
                                                          (password =
                                                             default_password)
                                                      in
                                                        if
                                                          not
                                                            (trivially_false
                                                               auth_function)
                                                        then
                                                          Lang.to_bool
                                                            (Lang.apply
                                                               ~t: Lang.
                                                                 bool_t
                                                               auth_function
                                                               [ ("",
                                                                  (Lang.
                                                                    string
                                                                    user));
                                                                 ("",
                                                                  (Lang.
                                                                    string
                                                                    password)) ])
                                                        else default_login
                                                    in
                                                      let dumpfile =
                                                        match s "dumpfile"
                                                        with
                                                        | "" -> None
                                                        | s -> Some s
                                                      in
                                                        let extra_headers 
                                                          =
                                                          List.map
                                                            (fun v ->
                                                               let f 
                                                                 (x, y) =
                                                                 ((Lang.
                                                                    to_string
                                                                    x),
                                                                  (Lang.
                                                                    to_string
                                                                    y))
                                                               in
                                                                 f
                                                                   (Lang.
                                                                    to_product
                                                                    v))
                                                            (Lang.to_list
                                                               (List.assoc
                                                                  "headers" p))
                                                        in
                                                          object (self)
                                                            inherit
                                                              Output.encoded
                                                                ~content_kind:
                                                                  kind
                                                                ~output_kind:
                                                                  "output.harbor"
                                                                ~infallible
                                                                ~autostart
                                                                ~on_start
                                                                ~on_stop
                                                                ~name: mount
                                                                source
                                                              
                                                            (** File descriptor where to dump. *)
                                                            val mutable
                                                              dump = None
                                                              
                                                            val mutable
                                                              encoder = None
                                                              
                                                            val mutable
                                                              clients =
                                                              Queue.create ()
                                                              
                                                            val clients_m =
                                                              Mutex.create ()
                                                              
                                                            val duppy_c =
                                                              Duppy.Monad.
                                                                Condition.
                                                                create
                                                                ~priority:
                                                                  Tutils.
                                                                  Non_blocking
                                                                Tutils.
                                                                scheduler
                                                              
                                                            val duppy_m =
                                                              Duppy.Monad.
                                                                Mutex.create
                                                                ~priority:
                                                                  Tutils.
                                                                  Non_blocking
                                                                Tutils.
                                                                scheduler
                                                              
                                                            val mutable
                                                              chunk_len = 0
                                                              
                                                            val mutable
                                                              burst_data = []
                                                              
                                                            val mutable
                                                              burst_pos = 0
                                                              
                                                            val metadata =
                                                              {
                                                                metadata =
                                                                  None;
                                                                metadata_m =
                                                                  Mutex.
                                                                    create ();
                                                              }
                                                              
                                                            method encode =
                                                              fun frame ofs
                                                                len ->
                                                                (Utils.
                                                                   get_some
                                                                   encoder).
                                                                  Encoder.
                                                                  encode
                                                                  frame ofs
                                                                  len
                                                              
                                                            method insert_metadata =
                                                              fun m ->
                                                                let m 
                                                                  =
                                                                  Encoder.
                                                                    Meta.
                                                                    to_metadata
                                                                    m in
                                                                let meta 
                                                                  =
                                                                  Hashtbl.
                                                                    create
                                                                    (
                                                                    Hashtbl.
                                                                    length m) in
                                                                let f 
                                                                  =
                                                                  Configure.
                                                                    recode_tag
                                                                    ?out_enc
                                                                in
                                                                  (Hashtbl.
                                                                    iter
                                                                    (fun a b
                                                                    ->
                                                                    Hashtbl.
                                                                    add meta
                                                                    a (
                                                                    f b)) m;
                                                                   if
                                                                    icy_metadata
                                                                   then
                                                                    Tutils.
                                                                    mutexify
                                                                    metadata.
                                                                    metadata_m
                                                                    (fun ()
                                                                    ->
                                                                    metadata.
                                                                    metadata
                                                                    <-
                                                                    Some meta)
                                                                    ()
                                                                   else
                                                                    (Utils.
                                                                    get_some
                                                                    encoder).
                                                                    Encoder.
                                                                    insert_metadata
                                                                    (Encoder.
                                                                    Meta.
                                                                    export_metadata
                                                                    meta))
                                                              
                                                            method add_client =
                                                              fun ~protocol
                                                                ~headers ~uri
                                                                ~args s ->
                                                                let ip 
                                                                  =
                                                                  (* Show port = true to catch different clients from same
       * ip *)
                                                                  Utils.
                                                                    name_of_sockaddr
                                                                    ~show_port:
                                                                    true
                                                                    (
                                                                    Unix.
                                                                    getpeername
                                                                    s) in
                                                                let (metaint,
                                                                    icyheader) 
                                                                  =
                                                                  try
                                                                    (assert
                                                                    (((List.
                                                                    assoc
                                                                    "Icy-MetaData"
                                                                    headers)
                                                                    = "1") &&
                                                                    icy_metadata);
                                                                    (metaint,
                                                                    (Printf.
                                                                    sprintf
                                                                    "icy-metaint: %d\r\n"
                                                                    metaint)))
                                                                  with
                                                                  | _ ->
                                                                    ((-1),
                                                                    "") in
                                                                let extra_headers 
                                                                  =
                                                                  String.
                                                                    concat ""
                                                                    (
                                                                    List.map
                                                                    (fun
                                                                    (x, y) ->
                                                                    Printf.
                                                                    sprintf
                                                                    "%s: %s\r\n"
                                                                    x y)
                                                                    extra_headers) in
                                                                let reply 
                                                                  =
                                                                  Printf.
                                                                    sprintf
                                                                    "%s 200 OK\r\nContent-type: %s\r\n%s%s\r\n"
                                                                    protocol
                                                                    format
                                                                    icyheader
                                                                    extra_headers in
                                                                let buffer 
                                                                  =
                                                                  Buffer.
                                                                    create
                                                                    buflen
                                                                in
                                                                  ((match 
                                                                    (Utils.
                                                                    get_some
                                                                    encoder).
                                                                    Encoder.
                                                                    header
                                                                    with
                                                                    | 
                                                                    Some s ->
                                                                    Buffer.
                                                                    add_string
                                                                    buffer s
                                                                    | 
                                                                    None ->
                                                                    ());
                                                                   let close 
                                                                    () =
                                                                    try
                                                                    Unix.
                                                                    close s
                                                                    with
                                                                    | 
                                                                    _ -> () in
                                                                   let rec
                                                                    client 
                                                                    =
                                                                    {
                                                                    buffer =
                                                                    buffer;
                                                                    condition =
                                                                    duppy_c;
                                                                    condition_m =
                                                                    duppy_m;
                                                                    metaint =
                                                                    metaint;
                                                                    meta =
                                                                    metadata;
                                                                    latest_meta =
                                                                    "\000";
                                                                    metapos =
                                                                    0;
                                                                    url = url;
                                                                    mutex =
                                                                    Mutex.
                                                                    create ();
                                                                    state =
                                                                    Hello;
                                                                    chunk =
                                                                    chunk;
                                                                    close =
                                                                    close;
                                                                    handler =
                                                                    handler;
                                                                    }
                                                                   and
                                                                    handler 
                                                                    =
                                                                    {
                                                                    Duppy.
                                                                    Monad.Io.
                                                                    scheduler =
                                                                    Tutils.
                                                                    scheduler;
                                                                    socket =
                                                                    s;
                                                                    data = "";
                                                                    on_error =
                                                                    (fun e ->
                                                                    ((
                                                                    match e
                                                                    with
                                                                    | 
                                                                    Duppy.Io.
                                                                    Io_error
                                                                    ->
                                                                    self#log#
                                                                    f 5
                                                                    "I/O error"
                                                                    | 
                                                                    Duppy.Io.
                                                                    Unix (c,
                                                                    p, m) ->
                                                                    self#log#
                                                                    f 5 "%s"
                                                                    (Utils.
                                                                    error_message
                                                                    (Unix.
                                                                    Unix_error
                                                                    (c, p, m)))
                                                                    | 
                                                                    Duppy.Io.
                                                                    Unknown e
                                                                    ->
                                                                    self#log#
                                                                    f 5 "%s"
                                                                    (Utils.
                                                                    error_message
                                                                    e));
                                                                    self#log#
                                                                    f 4
                                                                    "Client %s disconnected"
                                                                    ip;
                                                                    Tutils.
                                                                    mutexify
                                                                    client.
                                                                    mutex
                                                                    (fun ()
                                                                    ->
                                                                    (client.
                                                                    state <-
                                                                    Done;
                                                                    Buffer.
                                                                    reset
                                                                    buffer;
                                                                    close ()))
                                                                    ();
                                                                    on_disconnect
                                                                    ip;
                                                                    Harbor.
                                                                    Close ""));
                                                                    }
                                                                   in
                                                                    Duppy.
                                                                    Monad.
                                                                    bind
                                                                    (Duppy.
                                                                    Monad.
                                                                    catch
                                                                    (if
                                                                    (default_user
                                                                    <> "") ||
                                                                    (not
                                                                    (trivially_false
                                                                    auth_function))
                                                                    then
                                                                    Harbor.
                                                                    auth_check
                                                                    ~args
                                                                    ~login:
                                                                    (default_user,
                                                                    login)
                                                                    handler
                                                                    uri
                                                                    headers
                                                                    else
                                                                    Duppy.
                                                                    Monad.
                                                                    return ())
                                                                    (function
                                                                    | 
                                                                    Harbor.
                                                                    Reply _
                                                                    ->
                                                                    assert
                                                                    false
                                                                    | 
                                                                    Harbor.
                                                                    Close s
                                                                    ->
                                                                    (self#log#
                                                                    f 4
                                                                    "Client %s failed to authenticate!"
                                                                    ip;
                                                                    client.
                                                                    state <-
                                                                    Done;
                                                                    Harbor.
                                                                    reply s)))
                                                                    (fun ()
                                                                    ->
                                                                    Duppy.
                                                                    Monad.
                                                                    bind
                                                                    (self#log#
                                                                    f 4
                                                                    "Client %s connected"
                                                                    ip;
                                                                    Duppy.
                                                                    Monad.Io.
                                                                    exec
                                                                    ~priority:
                                                                    Tutils.
                                                                    Maybe_blocking
                                                                    handler
                                                                    (Tutils.
                                                                    mutexify
                                                                    clients_m
                                                                    (fun ()
                                                                    ->
                                                                    Queue.
                                                                    push
                                                                    client
                                                                    clients)
                                                                    ();
                                                                    let h_headers 
                                                                    =
                                                                    Hashtbl.
                                                                    create
                                                                    (List.
                                                                    length
                                                                    headers)
                                                                    in
                                                                    (List.
                                                                    iter
                                                                    (fun
                                                                    (x, y) ->
                                                                    Hashtbl.
                                                                    add
                                                                    h_headers
                                                                    x y)
                                                                    headers;
                                                                    on_connect
                                                                    ~protocol
                                                                    ~uri
                                                                    ~headers:
                                                                    h_headers
                                                                    ip;
                                                                    Duppy.
                                                                    Monad.
                                                                    return ())))
                                                                    (fun ()
                                                                    ->
                                                                    Harbor.
                                                                    relayed
                                                                    reply)))
                                                              
                                                            method send =
                                                              fun b ->
                                                                let slen 
                                                                  =
                                                                  String.
                                                                    length b
                                                                in
                                                                  if slen > 0
                                                                  then
                                                                    (chunk_len
                                                                    <-
                                                                    chunk_len
                                                                    +
                                                                    (String.
                                                                    length b);
                                                                    (let wake_up 
                                                                    =
                                                                    if
                                                                    chunk_len
                                                                    >= chunk
                                                                    then
                                                                    (chunk_len
                                                                    <- 0;
                                                                    true)
                                                                    else
                                                                    false in
                                                                    let rec
                                                                    f acc len
                                                                    l =
                                                                    match l
                                                                    with
                                                                    | 
                                                                    x :: l'
                                                                    ->
                                                                    let len' 
                                                                    =
                                                                    String.
                                                                    length x
                                                                    in
                                                                    if
                                                                    (len +
                                                                    len') <
                                                                    burst
                                                                    then
                                                                    f
                                                                    (x ::
                                                                    acc)
                                                                    (len +
                                                                    len') l'
                                                                    else
                                                                    ((x ::
                                                                    acc),
                                                                    ((len' -
                                                                    burst) +
                                                                    len))
                                                                    | 
                                                                    [] ->
                                                                    (acc, 0) in
                                                                    let 
                                                                    (data,
                                                                    pos) 
                                                                    =
                                                                    f [] 0
                                                                    (b ::
                                                                    (List.rev
                                                                    burst_data))
                                                                    in
                                                                    (burst_data
                                                                    <- data;
                                                                    burst_pos
                                                                    <- pos;
                                                                    let new_clients 
                                                                    =
                                                                    Queue.
                                                                    create ()
                                                                    in
                                                                    Tutils.
                                                                    mutexify
                                                                    clients_m
                                                                    (fun ()
                                                                    ->
                                                                    (Queue.
                                                                    iter
                                                                    (fun c ->
                                                                    let start 
                                                                    =
                                                                    Tutils.
                                                                    mutexify
                                                                    c.mutex
                                                                    (fun ()
                                                                    ->
                                                                    match 
                                                                    c.state
                                                                    with
                                                                    | 
                                                                    Hello ->
                                                                    ((
                                                                    match burst_data
                                                                    with
                                                                    | 
                                                                    x :: l ->
                                                                    (Buffer.
                                                                    add_substring
                                                                    c.buffer
                                                                    x
                                                                    burst_pos
                                                                    ((String.
                                                                    length x)
                                                                    -
                                                                    burst_pos);
                                                                    List.iter
                                                                    (Buffer.
                                                                    add_string
                                                                    c.buffer)
                                                                    l)
                                                                    | 
                                                                    _ -> ());
                                                                    Queue.
                                                                    push c
                                                                    new_clients;
                                                                    true)
                                                                    | 
                                                                    Sending
                                                                    ->
                                                                    let buf 
                                                                    =
                                                                    Buffer.
                                                                    length
                                                                    c.buffer
                                                                    in
                                                                    (if
                                                                    (buf +
                                                                    slen) >
                                                                    buflen
                                                                    then
                                                                    Utils.
                                                                    buffer_drop
                                                                    c.buffer
                                                                    (min buf
                                                                    slen)
                                                                    else ();
                                                                    Buffer.
                                                                    add_string
                                                                    c.buffer
                                                                    b;
                                                                    Queue.
                                                                    push c
                                                                    new_clients;
                                                                    false)
                                                                    | 
                                                                    Done ->
                                                                    false) ()
                                                                    in
                                                                    if start
                                                                    then
                                                                    Duppy.
                                                                    Monad.run
                                                                    ~return:
                                                                    c.close
                                                                    ~raise:
                                                                    c.close
                                                                    (client_task
                                                                    c)
                                                                    else ())
                                                                    clients;
                                                                    if
                                                                    wake_up
                                                                    &&
                                                                    ((Queue.
                                                                    length
                                                                    new_clients)
                                                                    > 0)
                                                                    then
                                                                    Duppy.
                                                                    Monad.run
                                                                    ~return:
                                                                    (fun ()
                                                                    -> ())
                                                                    ~raise:
                                                                    (fun ()
                                                                    -> ())
                                                                    (Duppy.
                                                                    Monad.
                                                                    Condition.
                                                                    broadcast
                                                                    duppy_c)
                                                                    else ();
                                                                    clients
                                                                    <-
                                                                    new_clients))
                                                                    ())))
                                                                  else ()
                                                              
                                                            method output_start =
                                                              (assert
                                                                 (encoder =
                                                                    None);
                                                               let enc 
                                                                 =
                                                                 encoder_factory
                                                                   self#id
                                                               in
                                                                 (encoder <-
                                                                    Some
                                                                    (enc
                                                                    Encoder.
                                                                    Meta.
                                                                    empty_metadata);
                                                                  let handler 
                                                                    ~http_method
                                                                    ~protocol
                                                                    ~data
                                                                    ~headers
                                                                    ~socket
                                                                    uri =
                                                                    if
                                                                    http_method
                                                                    <> "GET"
                                                                    then
                                                                    Harbor.
                                                                    reply
                                                                    (Harbor.
                                                                    http_error_page
                                                                    405
                                                                    "Method Not Allowed"
                                                                    "Method not allowed!")
                                                                    else
                                                                    (let rex 
                                                                    =
                                                                    Pcre.
                                                                    regexp
                                                                    "^(.+)\\?(.+)$" in
                                                                    let 
                                                                    (base_uri,
                                                                    args) 
                                                                    =
                                                                    try
                                                                    let sub 
                                                                    =
                                                                    Pcre.exec
                                                                    ~rex: rex
                                                                    uri
                                                                    in
                                                                    ((
                                                                    Pcre.
                                                                    get_substring
                                                                    sub 1),
                                                                    (Pcre.
                                                                    get_substring
                                                                    sub 2))
                                                                    with
                                                                    | 
                                                                    Not_found
                                                                    ->
                                                                    (uri, "") in
                                                                    let args 
                                                                    =
                                                                    Http.
                                                                    args_split
                                                                    args
                                                                    in
                                                                    self#
                                                                    add_client
                                                                    ~protocol
                                                                    ~headers
                                                                    ~uri
                                                                    ~args
                                                                    socket)
                                                                  in
                                                                    (Harbor.
                                                                    add_http_handler
                                                                    ~port
                                                                    ~uri
                                                                    handler;
                                                                    match dumpfile
                                                                    with
                                                                    | 
                                                                    Some f ->
                                                                    dump <-
                                                                    Some
                                                                    (open_out_bin
                                                                    f)
                                                                    | 
                                                                    None ->
                                                                    ())))
                                                              
                                                            method output_stop =
                                                              (ignore
                                                                 ((Utils.
                                                                    get_some
                                                                    encoder).
                                                                    Encoder.
                                                                    stop ());
                                                               encoder <-
                                                                 None;
                                                               Harbor.
                                                                 remove_http_handler
                                                                 ~port ~uri
                                                                 ();
                                                               let new_clients 
                                                                 =
                                                                 Queue.create
                                                                   ()
                                                               in
                                                                 (Tutils.
                                                                    mutexify
                                                                    clients_m
                                                                    (
                                                                    fun () ->
                                                                    (Queue.
                                                                    iter
                                                                    (fun c ->
                                                                    Tutils.
                                                                    mutexify
                                                                    c.mutex
                                                                    (fun ()
                                                                    ->
                                                                    c.state
                                                                    <- Done)
                                                                    ())
                                                                    clients;
                                                                    clients
                                                                    <-
                                                                    new_clients))
                                                                    ();
                                                                  match dump
                                                                  with
                                                                  | Some f ->
                                                                    close_out
                                                                    f
                                                                  | None ->
                                                                    ()))
                                                              
                                                            method output_reset =
                                                              (self#
                                                                 output_stop;
                                                               self#
                                                                 output_start)
                                                              
                                                          end
  
let () =
  let k = Lang.univ_t 1
  in
    Lang.add_operator "output.harbor" ~category: Lang.Output
      ~descr: "Encode and output the stream using the harbor server."
      (proto k) ~kind: (Lang.Unconstrained k)
      (fun p kind -> (new output kind p :> Source.source))
  
