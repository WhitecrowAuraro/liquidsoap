(*****************************************************************************

  Liquidsoap, a programmable stream generator.
  Copyright 2003-2018 Savonet team

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

(** Generate a white noise *)

class noise ~kind duration =
  let ctype = Frame.type_of_kind kind in
  let () = assert (ctype.Frame.midi = 0) in
object

  inherit Synthesized.source ~seek:true
                             ~name:"noise" kind duration

  method private synthesize frame off len =
    let content = Frame.content_of_type frame off ctype in
    begin
      let off = Frame.audio_of_master off in
      let len = Frame.audio_of_master len in
      let b = content.Frame.audio in
      Audio.Generator.white_noise b off len
    end ;
    begin
      let off = Frame.video_of_master off in
      let len = Frame.video_of_master len in
      let b = content.Frame.video in
      for c = 0 to Array.length b - 1 do
        Video.randomize b.(c) off len
      done
    end

end

let () =
  let k =
    Lang.frame_kind_t ~audio:(Lang.univ_t 1) ~video:(Lang.univ_t 2) ~midi:Lang.zero_t
  in
    Lang.add_operator "noise"
      ~category:Lang.Input
      ~descr:"Generate (audio and/or video) white noise."
      [ "duration", Lang.float_t, Some (Lang.float 0.), None ]
      ~kind:(Lang.Unconstrained k)
      (fun p kind ->
         new noise ~kind (Lang.to_float (List.assoc "duration" p)))
