(* reventless-ppx-read — print one ReScript file's declarations with their spans.

     read [--bsc <path-to-bsc>] <file.res>
     read --vocabulary

   `--vocabulary` prints every attribute the PPX reads (Vocabulary.all) and
   needs no bsc.

   The file is parsed by the compiler: this executable runs bsc with itself as
   the ppx, because bsc hands a ppx the tree in the binary format ppxlib reads
   (its own `-bs-ast` output is not). In that second role it is called as

     read --emit <out.json> --source <file.res> <input.ast> <output.ast>

   writes the JSON, and passes the tree through unchanged. See
   docs/plans/source-reader-with-spans.md. *)

let read_file path =
  let ic = open_in_bin path in
  let s = really_input_string ic (in_channel_length ic) in
  close_in ic;
  s

let write_file path s =
  let oc = open_out_bin path in
  output_string oc s;
  close_out oc

let fail fmt = Printf.ksprintf (fun m -> prerr_endline ("reventless-ppx-read: " ^ m); exit 1) fmt

(* ── ppx role ───────────────────────────────────────────────────────────── *)

let emit ~out ~source ~input ~output =
  (match Ppxlib.Ast_io.read_binary input with
   | Error e -> fail "cannot read the parse tree: %s" e
   | Ok t -> (
     match Ppxlib.Ast_io.get_ast t with
     | Impl str ->
       let json = ReventlessPpx__SourceReader.file_json ~fname:source ~src:(read_file source) str in
       write_file out (Yojson.Safe.to_string json)
     | Intf _ -> fail "%s is an interface; only implementations are read" source));
  write_file output (read_file input)

(* ── vocabulary ─────────────────────────────────────────────────────────── *)

(* The version of the package this binary ships in: the per-platform package's
   manifest beside it, or the PPX package's above a local build. The release
   resolves the version after the build, so it cannot be compiled in. *)
let own_version () : string option =
  let manifest dir =
    let p = Filename.concat dir "package.json" in
    if not (Sys.file_exists p) then None
    else
      match Yojson.Safe.from_file p with
      | `Assoc kv -> (
        match List.assoc_opt "name" kv, List.assoc_opt "version" kv with
        | Some (`String n), Some (`String v)
          when String.length n >= 29 && String.equal (String.sub n 0 29) "@reventlessdev/reventless-ppx" ->
          Some v
        | _ -> None)
      | _ | (exception _) -> None
  in
  let rec up dir =
    match manifest dir with
    | Some _ as v -> v
    | None ->
      let parent = Filename.dirname dir in
      if String.equal parent dir then None else up parent
  in
  let exe = Sys.executable_name in
  up (Filename.dirname (if Filename.is_relative exe then Filename.concat (Sys.getcwd ()) exe else exe))

let vocabulary () =
  print_endline (Yojson.Safe.pretty_to_string (ReventlessPpx__Vocabulary.to_json ~version:(own_version ())))

(* ── command-line role ──────────────────────────────────────────────────── *)

let platforms = [ "darwin-arm64"; "darwin-x64"; "linux-x64"; "linux-arm64"; "win32-x64" ]

(* The bsc of the workspace the file is in: the nearest node_modules holding
   ReScript's platform package, walking up from the file. *)
let find_bsc (file : string) : string option =
  let rec up dir =
    let found =
      List.find_map
        (fun p ->
          let c = Filename.concat dir (Filename.concat "node_modules/@rescript" (Filename.concat p "bin/bsc.exe")) in
          if Sys.file_exists c then Some c else None)
        platforms
    in
    match found with
    | Some _ -> found
    | None ->
      let parent = Filename.dirname dir in
      if String.equal parent dir then None else up parent
  in
  let abs = if Filename.is_relative file then Filename.concat (Sys.getcwd ()) file else file in
  up (Filename.dirname abs)

let run ~bsc ~file =
  let self = Sys.executable_name in
  let out = Filename.temp_file "reventless-read" ".json" in
  let ast = Filename.temp_file "reventless-read" ".ast" in
  let ppx = Filename.quote_command self [ "--emit"; out; "--source"; file ] in
  let cmd = Filename.quote_command bsc [ "-ppx"; ppx; "-bs-ast"; "-o"; ast; file ] in
  let code = Sys.command cmd in
  let json = if code = 0 && Sys.file_exists out then Some (read_file out) else None in
  List.iter (fun f -> try Sys.remove f with _ -> ()) [ out; ast ];
  match json with
  | Some j -> print_string j
  | None -> fail "bsc could not parse %s (exit %d)" file code

let () =
  match Array.to_list Sys.argv |> List.tl with
  | [ "--emit"; out; "--source"; source; input; output ] -> emit ~out ~source ~input ~output
  | [ "--vocabulary" ] -> vocabulary ()
  | [ "--bsc"; bsc; file ] -> run ~bsc ~file
  | [ file ] -> (
    match Sys.getenv_opt "RESCRIPT_BSC_EXE", find_bsc file with
    | Some bsc, _ | None, Some bsc -> run ~bsc ~file
    | None, None -> fail "no bsc found above %s; pass --bsc <path>" file)
  | _ -> fail "usage: read [--bsc <path-to-bsc>] <file.res> | read --vocabulary"
