open Ppxlib

let read_json path =
  try
    let ic = open_in path in
    let n = in_channel_length ic in
    let s = Bytes.create n in
    really_input ic s 0 n;
    close_in ic;
    Some (Yojson.Safe.from_string (Bytes.to_string s))
  with _ -> None

type pkg_info = {
  name : string;
  root : string;
  namespace : string option;
  has_reventless_spec : bool;
}

let cache : (string, pkg_info option) Hashtbl.t = Hashtbl.create 16

let rec find_package dir =
  match Hashtbl.find_opt cache dir with
  | Some result -> result
  | None ->
    let result =
      let pkg_path = Filename.concat dir "package.json" in
      if Sys.file_exists pkg_path then
        match read_json pkg_path with
        | Some json ->
          (match Yojson.Safe.Util.member "name" json with
           | `String name ->
             let rescript_path = Filename.concat dir "rescript.json" in
             let namespace, has_reventless_spec =
               match read_json rescript_path with
               | Some rjson ->
                 let ns = match Yojson.Safe.Util.member "namespace" rjson with
                   | `String s -> Some s
                   | _ -> None
                 in
                 let has_spec =
                   match Yojson.Safe.Util.member "dependencies" rjson with
                   | `List deps ->
                     List.exists (fun d ->
                       match d with
                       | `String s -> String.length s >= 16 &&
                         let suffix = "reventless-spec" in
                         let slen = String.length s in
                         let suflen = String.length suffix in
                         slen >= suflen && String.sub s (slen - suflen) suflen = suffix
                       | _ -> false
                     ) deps
                   | _ -> false
                 in
                 (ns, has_spec)
               | None -> (None, false)
             in
             Some { name; root = dir; namespace; has_reventless_spec }
           | _ -> walk_parent dir)
        | None -> walk_parent dir
      else
        walk_parent dir
    in
    Hashtbl.replace cache dir result;
    result

and walk_parent dir =
  let parent = Filename.dirname dir in
  if String.equal parent dir then None
  else find_package parent

let normalize_separators path =
  String.map (fun c -> if c = '\\' then '/' else c) path

let make_relative ~base path =
  let base_len = String.length base in
  let path_len = String.length path in
  if path_len > base_len && String.sub path 0 base_len = base then
    let start = if path.[base_len] = '/' || path.[base_len] = '\\' then base_len + 1 else base_len in
    String.sub path start (path_len - start)
  else
    path

let abs_path_of loc =
  let source_file = loc.loc_start.pos_fname in
  if Filename.is_relative source_file then
    normalize_separators (Filename.concat (Sys.getcwd ()) source_file)
  else
    normalize_separators source_file

let find_package_for loc =
  let abs_path = abs_path_of loc in
  let dir = Filename.dirname abs_path in
  find_package dir

let compute_specifier loc =
  let abs_path = abs_path_of loc in
  let dir = Filename.dirname abs_path in
  match find_package dir with
  | Some pkg ->
    let rel = make_relative ~base:(normalize_separators pkg.root) abs_path in
    let mjs = rel ^ ".mjs" in
    pkg.name ^ "/" ^ mjs
  | None ->
    Location.raise_errorf ~loc
      "[reventless-ppx] No package.json found for %s" loc.loc_start.pos_fname

let is_spec_namespace pkg =
  match pkg.namespace with
  | Some ns -> Util.strip_suffix ns "Spec" <> ns
  | None -> false

let plugin_name_from_namespace pkg =
  match pkg.namespace with
  | Some ns -> Util.strip_suffix (Util.strip_suffix ns "Spec") "Plugin"
  | None -> ""

let gen_module_url ~loc specifier =
  [%stri let moduleUrl : string = [%e Ast_builder.Default.estring ~loc specifier]]
