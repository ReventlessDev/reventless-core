(* The drift guard: Vocabulary.all names exactly the attributes the modules in
   src/ppx match, and each entry's readBy names exactly the modules that match it.
   A name is found where it is compared with an attribute's name, or held in a
   constant or a list the comparison reads. *)

module V = ReventlessPpx__Vocabulary

let failures = ref 0

let fail fmt =
  Printf.ksprintf
    (fun m ->
      Printf.printf "  FAIL: %s\n" m;
      incr failures)
    fmt

let ok label = Printf.printf "  ok: %s\n" label

let read_file path =
  let ic = open_in_bin path in
  let s = really_input_string ic (in_channel_length ic) in
  close_in ic;
  s

let patterns =
  List.map Str.regexp
    [ {|attr_name\.txt[ \n]+"\([^"]+\)"|};
      {|\(has_attr\|find_attr\|attr_is\)[ \n]+"\([^"]+\)"|};
      {|String\.equal name "\([^"]+\)"|};
      {|let [a-z_]*attr[a-z_]* = "\([^"]+\)"|} ]

let not_authored n =
  String.equal n "schema"
  || List.exists
       (fun p -> String.length n >= String.length p && String.equal (String.sub n 0 (String.length p)) p)
       [ "res."; "s."; "ocaml." ]

(* The names a module's source matches: the last group of each pattern. *)
let names_in (src : string) : string list =
  List.concat_map
    (fun re ->
      let rec go pos acc =
        match Str.search_forward re src pos with
        | exception Not_found -> List.rev acc
        | i ->
          let g = try Str.matched_group 2 src with Not_found | Invalid_argument _ -> Str.matched_group 1 src in
          go (i + 1) (g :: acc)
      in
      go 0 [])
    patterns
  |> List.filter (fun n -> not (not_authored n))
  |> List.sort_uniq String.compare

(* Names held in lists rather than written at the comparison. *)
let listed =
  [ ("TaggedUnionInference", ReventlessPpx__TaggedUnionInference.refused_field_attrs);
    ("TransitionAnnotation", List.map fst ReventlessPpx__TransitionAnnotation.removed_attrs);
    ("ReventlessPpx", List.map ReventlessPpx.impl_kind_attr_name ReventlessPpx.all_impl_kinds) ]

let module_of path = Filename.remove_extension (Filename.basename path)

(* (module, name) for every match. *)
let matches (files : (string * string) list) : (string * string) list =
  List.concat_map (fun (m, src) -> List.map (fun n -> (m, n)) (names_in src)) files
  @ List.concat_map (fun (m, ns) -> List.map (fun n -> (m, n)) ns) listed
  |> List.sort_uniq compare

let table_names = List.map (fun (x : V.entry) -> x.name) V.all

(* The drift check itself: names matched but not listed, and listed but not matched. *)
let drift (found : (string * string) list) : string list * string list =
  let names = List.sort_uniq String.compare (List.map snd found) in
  ( List.filter (fun n -> not (List.mem n table_names)) names,
    List.filter (fun n -> not (List.mem n names)) table_names )

let () =
  let paths =
    Array.to_list Sys.argv |> List.tl
    |> List.filter (fun p ->
           Filename.check_suffix p ".ml"
           && (not (Filename.check_suffix p ".pp.ml"))
           && not (String.equal (module_of p) "Vocabulary"))
  in
  let files = List.map (fun p -> (module_of p, read_file p)) paths in
  if List.length files < 20 then fail "found only %d modules in src/ppx" (List.length files);
  let found = matches files in
  let unlisted, unmatched = drift found in
  List.iter (fail "@%s is matched in src/ppx but missing from Vocabulary.all") unlisted;
  List.iter (fail "@%s is in Vocabulary.all but matched nowhere in src/ppx") unmatched;
  if unlisted = [] && unmatched = [] then
    ok (Printf.sprintf "Vocabulary.all lists the %d names src/ppx matches" (List.length table_names));
  let dupes = List.length table_names - List.length (List.sort_uniq String.compare table_names) in
  if dupes > 0 then fail "Vocabulary.all lists %d names twice" dupes else ok "every name is listed once";
  let stale =
    List.filter_map
      (fun (x : V.entry) ->
        let by = List.filter_map (fun (m, n) -> if String.equal n x.name then Some m else None) found in
        if List.sort compare by = List.sort compare x.read_by then None
        else Some (Printf.sprintf "@%s: readBy [%s], matched in [%s]" x.name
                     (String.concat "; " x.read_by) (String.concat "; " by)))
      V.all
  in
  List.iter (fail "%s") stale;
  if stale = [] then ok "every readBy names the modules that match it";
  (* The guard catches a module matching a name the table does not list. *)
  let fixture = {|let has_x attrs = List.exists (fun a -> String.equal a.attr_name.txt "notInTheTable") attrs|} in
  (match drift (matches (files @ [ ("Fixture", fixture) ])) with
   | [ "notInTheTable" ], [] -> ok "a fixture matching an unlisted name fails the guard"
   | _ -> fail "the guard did not report the fixture's unlisted name");
  (* The printed vocabulary is JSON with an entry per name. *)
  let json = Yojson.Safe.to_string (V.to_json ~version:(Some "0.0.0")) in
  (match Yojson.Safe.from_string json with
   | `Assoc kv -> (
     match List.assoc_opt "attributes" kv with
     | Some (`List xs) when List.length xs = List.length V.all -> ok "to_json has an entry for every name"
     | _ -> fail "to_json's attributes do not match Vocabulary.all")
   | _ -> fail "to_json is not an object");
  if !failures > 0 then exit 1 else print_endline "ALL VOCABULARY CHECKS PASSED"
