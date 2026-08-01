(* SidecarEmit.ml — Plan 06 Phase 1.

   Emits a structured `<Stem>.model.json` sidecar next to a `@@reventless.spec`
   `.res` file when (and only when) the environment variable
   REVENTLESS_EMIT_SIDECAR=1 is set. Ordinary `rescript build` runs write
   nothing new; the reverse-codegen `export` CLI sets the flag before it
   triggers a build, then reads the sidecars back (Plan 06 Phase 3).

   The sidecar is a per-file *canonical-model fragment* (Decision 2): every
   `@schema type` (command / event / consumedEvent / error / state / …) is
   captured as a list of "elements" (variant constructors, or the record
   itself) whose fields carry the exact `Model.field` JSON shape — name, kind,
   isId / isIndex / isCompositeTag, and the resolved DCB-tag `dcbRole` — so the
   assembler can decode it with `Model.fieldFromJson` directly. `let` config
   constants (targetName / maxRetries / heartbeatInterval) are captured too.

   This module reads the spec body *before* `DcbTagInference` rewrites the
   field annotations into `@s.matches(...)`, so the original `@partitionTag` /
   `@noDcbTag` / `@dcbTag` / `@id` / `@index` intent is still visible. *)

open Ppxlib

(* ── Gating ─────────────────────────────────────────────────────────────── *)

let enabled =
  lazy
    (match Sys.getenv_opt "REVENTLESS_EMIT_SIDECAR" with
     | Some ("1" | "true" | "TRUE") -> true
     | _ -> false)

let is_enabled () = Lazy.force enabled

(* ── Small AST helpers ──────────────────────────────────────────────────── *)

let has_attr (name : string) (attrs : attributes) : bool =
  List.exists (fun (a : attribute) -> String.equal a.attr_name.txt name) attrs

let attr_names (attrs : attributes) : string list =
  List.map (fun (a : attribute) -> a.attr_name.txt) attrs

let is_schema_type (td : type_declaration) : bool =
  has_attr "schema" td.ptype_attributes

let ends_with s suffix =
  let ls = String.length s and lf = String.length suffix in
  ls >= lf && String.equal (String.sub s (ls - lf) lf) suffix

let flatten_longident (lid : Longident.t) : string =
  String.concat "." (Longident.flatten_exn lid)

(* The set of `@schema type` names whose fields participate in DCB tagging.
   Mirrors `EventModelingImport.resolveDcbRole`'s `~dcbContext`: command / event
   / consumedEvent fields can carry DCB roles; state / error / todoItem fields
   keep identity via `@id`, not DCB tags. *)
let is_dcb_context = function
  | "command" | "event" | "consumedEvent" | "sourceEvent" | "inboundCommand" ->
    true
  | _ -> false

(* ── core_type → Model.fieldKind JSON ───────────────────────────────────── *)

let rec kind_of_type (ct : core_type) : Yojson.Safe.t =
  match ct.ptyp_desc with
  | Ptyp_constr ({ txt = Lident "string"; _ }, []) ->
    `Assoc [ ("kind", `String "string") ]
  | Ptyp_constr ({ txt = Lident "int"; _ }, []) ->
    `Assoc [ ("kind", `String "int") ]
  | Ptyp_constr ({ txt = Lident "float"; _ }, []) ->
    `Assoc [ ("kind", `String "float") ]
  | Ptyp_constr ({ txt = Lident "bool"; _ }, []) ->
    `Assoc [ ("kind", `String "bool") ]
  | Ptyp_constr ({ txt = Lident ("array" | "list"); _ }, [ t ]) ->
    `Assoc [ ("kind", `String "list"); ("of_", kind_of_type t) ]
  | Ptyp_constr ({ txt = Lident "option"; _ }, [ t ]) ->
    `Assoc [ ("kind", `String "optional"); ("of_", kind_of_type t) ]
  | Ptyp_constr ({ txt; _ }, _) ->
    `Assoc [ ("kind", `String "custom"); ("name", `String (flatten_longident txt)) ]
  | _ -> `Assoc [ ("kind", `String "custom"); ("name", `String "Unknown") ]

let is_string_type (ct : core_type) : bool =
  match ct.ptyp_desc with
  | Ptyp_constr ({ txt = Lident "string"; _ }, []) -> true
  | _ -> false

let is_array_string_type (ct : core_type) : bool =
  match ct.ptyp_desc with
  | Ptyp_constr ({ txt = Lident "array"; _ }, [ elem ]) -> is_string_type elem
  | _ -> false

(* ── dcbRole resolution (from raw field attributes) ─────────────────────── *)

(* Replicates `EventModelingImport.resolveDcbRole` / `DcbTagInference`, reading
   the original annotations the PPX is about to consume. Explicit annotations
   win; otherwise a `*Id: string` / `*Ids: array<string>` field is auto-tagged. *)
let dcb_role_json ~dcb_context ~(name : string) ~(ct : core_type)
    ~(attrs : attributes) : Yojson.Safe.t =
  let role s = `Assoc [ ("role", `String s) ] in
  if not dcb_context then role "noTag"
  else if has_attr "partitionTag" attrs then role "partition"
  else if has_attr "noDcbTag" attrs then role "suppressed"
  else if has_attr "dcbTag" attrs then
    let key =
      match DcbTagInference.get_explicit_dcb_tag_key attrs with
      | Some k -> k
      | None -> name
    in
    `Assoc [ ("role", `String "customKey"); ("key", `String key) ]
  else if is_array_string_type ct && ends_with name "Ids" then
    role "autoStringForKey"
  else if is_string_type ct && ends_with name "Id" then role "autoString"
  else role "noTag"

(* ── label_declaration → Model.field JSON ───────────────────────────────── *)

let field_json ~dcb_context (ld : label_declaration) : Yojson.Safe.t =
  let name = ld.pld_name.txt in
  let attrs = ld.pld_attributes in
  let is_id = has_attr "id" attrs || has_attr "compositeId" attrs in
  let is_index = has_attr "index" attrs in
  let is_composite =
    has_attr "compositeId" attrs
    || has_attr "compositeSubId" attrs
    || has_attr "compositePartitionTag" attrs
  in
  `Assoc
    [ ("name", `String name);
      ("kind", kind_of_type ld.pld_type);
      ("isId", `Bool is_id);
      ("isIndex", `Bool is_index);
      ("isCompositeTag", `Bool is_composite);
      ("dcbRole", dcb_role_json ~dcb_context ~name ~ct:ld.pld_type ~attrs);
      ("example", `Null);
      ("annotations", `List (List.map (fun n -> `String n) (attr_names attrs))) ]

(* ── constructor / record → element JSON ────────────────────────────────── *)

let fields_of_args ~dcb_context (args : constructor_arguments) :
    Yojson.Safe.t list =
  match args with
  | Pcstr_record lds -> List.map (field_json ~dcb_context) lds
  | Pcstr_tuple _ -> [] (* payload-less or positional — no named fields *)

let element_json ~name ~fields : Yojson.Safe.t =
  `Assoc
    [ ("name", `String name);
      ("payloadless", `Bool (fields = []));
      ("fields", `List fields) ]

(* A `@schema type` declaration → one "types" entry. Variants expand to one
   element per constructor; records collapse to a single element named after
   the type. Abstract / alias types are skipped (returns None). *)
let type_entry (td : type_declaration) : Yojson.Safe.t option =
  let type_name = td.ptype_name.txt in
  let dcb_context = is_dcb_context type_name in
  match td.ptype_kind with
  | Ptype_variant ctors ->
    let elements =
      List.map
        (fun (c : constructor_declaration) ->
          let fields = fields_of_args ~dcb_context c.pcd_args in
          element_json ~name:c.pcd_name.txt ~fields)
        ctors
    in
    Some
      (`Assoc
         [ ("typeName", `String type_name);
           ("shape", `String "variant");
           ("elements", `List elements) ])
  | Ptype_record lds ->
    let fields = List.map (field_json ~dcb_context) lds in
    Some
      (`Assoc
         [ ("typeName", `String type_name);
           ("shape", `String "record");
           ("elements", `List [ element_json ~name:type_name ~fields ]) ])
  | _ -> None

(* ── config constants (let targetName / maxRetries / heartbeatInterval) ──── *)

let config_keys = [ "targetName"; "maxRetries"; "heartbeatInterval" ]

let literal_value (e : expression) : string option =
  match e.pexp_desc with
  | Pexp_constant (Pconst_integer (s, _)) -> Some s
  | Pexp_constant (Pconst_float (s, _)) -> Some s
  | Pexp_constant (Pconst_string (s, _, _)) -> Some ("\"" ^ s ^ "\"")
  | Pexp_construct ({ txt = Lident "true"; _ }, None) -> Some "true"
  | Pexp_construct ({ txt = Lident "false"; _ }, None) -> Some "false"
  | _ -> None

let config_entries (str : structure) : Yojson.Safe.t list =
  List.concat_map
    (fun (item : structure_item) ->
      match item.pstr_desc with
      | Pstr_value (_, vbs) ->
        List.filter_map
          (fun (vb : value_binding) ->
            match vb.pvb_pat.ppat_desc with
            | Ppat_var { txt; _ } when List.mem txt config_keys -> (
              match literal_value vb.pvb_expr with
              | Some v ->
                Some (`Assoc [ ("key", `String txt); ("value", `String v) ])
              | None -> None)
            | _ -> None)
          vbs
      | _ -> [])
    str

(* ── Top-level fragment + file write ────────────────────────────────────── *)

let filename_stem (fname : string) : string =
  let base = Filename.basename fname in
  match String.rindex_opt base '.' with
  | Some i -> String.sub base 0 i
  | None -> base

(* The sidecar `file` field is repo-root-relative so sidecars are
   machine-independent: walk up from the source file to the nearest `.git`
   entry (a directory, or a file in worktrees) and strip that prefix. Absent a
   repo root the path is kept as given — best-effort, like the write itself. *)
let repo_relative (fname : string) : string =
  if Filename.is_relative fname then fname
  else
    let rec find_root dir =
      if Sys.file_exists (Filename.concat dir ".git") then Some dir
      else
        let parent = Filename.dirname dir in
        if String.equal parent dir then None else find_root parent
    in
    match find_root (Filename.dirname fname) with
    | Some root ->
      let prefix = root ^ Filename.dir_sep in
      let plen = String.length prefix in
      if String.length fname > plen && String.equal (String.sub fname 0 plen) prefix
      then String.sub fname plen (String.length fname - plen)
      else fname
    | None -> fname

let fragment_json ~spec_name ~fname (body : structure) : Yojson.Safe.t =
  let types =
    List.concat_map
      (fun (item : structure_item) ->
        match item.pstr_desc with
        | Pstr_type (_, tds) ->
          List.filter_map
            (fun td -> if is_schema_type td then type_entry td else None)
            tds
        | _ -> [])
      body
  in
  `Assoc
    [ ("specName", `String spec_name);
      ("stem", `String (filename_stem fname));
      ("file", `String (repo_relative fname));
      ("types", `List types);
      ("config", `List (config_entries body)) ]

let sidecar_path (fname : string) : string =
  if Filename.check_suffix fname ".res" then
    Filename.chop_suffix fname ".res" ^ ".model.json"
  else fname ^ ".model.json"

(* Best-effort: never fail the compile if the write throws. *)
let write_sidecar ~spec_name ~fname (body : structure) : unit =
  try
    let json = fragment_json ~spec_name ~fname body in
    let path = sidecar_path fname in
    let oc = open_out path in
    output_string oc (Yojson.Safe.pretty_to_string json);
    output_char oc '\n';
    close_out oc
  with exn ->
    Printf.eprintf "[reventless-ppx] sidecar emit failed for %s: %s\n" fname
      (Printexc.to_string exn)

(* Public entry — called from the `Spec` branch of the dispatcher with the
   spec body captured *before* the DCB-tag transforms strip the annotations. *)
let maybe_emit ~spec_name ~fname (body : structure) : unit =
  if is_enabled () && fname <> "" then write_sidecar ~spec_name ~fname body

(* ════════════════════════════════════════════════════════════════════════
   GWT extraction (Plan 06 Phase 2) — emit <Stem>.gwt.json for @@reventless.gwt
   files whose `test` bodies use the inline-literal shape the forward emitter
   writes:

     describe("Spec", () => {
       // spec-id: <id>
       test("title", () =>
         givenEvents([E({..}), ..])
         ->whenCmd(C({..}))            // or ->whenInput(..)
         ->thenEvent(E({..}))          // or ->thenError(E) / ->thenState({..})
       )
     })

   ReScript desugars `a->f(b)` to `f(a, b)`, so the body is a nest of applies;
   we walk it and pick the given / when / then calls by function name. The
   `// spec-id:` lives in a comment (ppxlib drops comments) so it is recovered
   from the source text by line, correlated to each `test(...)` location.
   ════════════════════════════════════════════════════════════════════════ *)

(* ── example values from literal expressions (→ Model.exampleValue JSON) ── *)

let rec example_of_expr (e : expression) : Yojson.Safe.t option =
  match e.pexp_desc with
  | Pexp_constant (Pconst_string (s, _, _)) ->
    Some (`Assoc [ ("kind", `String "string"); ("value", `String s) ])
  | Pexp_constant (Pconst_integer (s, _)) -> (
    match int_of_string_opt s with
    | Some i -> Some (`Assoc [ ("kind", `String "int"); ("value", `Int i) ])
    | None -> None)
  | Pexp_constant (Pconst_float (s, _)) -> (
    match float_of_string_opt s with
    | Some f -> Some (`Assoc [ ("kind", `String "float"); ("value", `Float f) ])
    | None -> None)
  | Pexp_construct ({ txt = Lident "true"; _ }, None) ->
    Some (`Assoc [ ("kind", `String "bool"); ("value", `Bool true) ])
  | Pexp_construct ({ txt = Lident "false"; _ }, None) ->
    Some (`Assoc [ ("kind", `String "bool"); ("value", `Bool false) ])
  | Pexp_construct ({ txt = Lident "None"; _ }, None) ->
    Some (`Assoc [ ("kind", `String "null") ])
  | Pexp_construct ({ txt = Lident "Some"; _ }, Some inner) -> example_of_expr inner
  | Pexp_array els ->
    Some
      (`Assoc
         [ ("kind", `String "list");
           ("items", `List (List.filter_map example_of_expr els)) ])
  | Pexp_record (fields, _) ->
    Some
      (`Assoc
         [ ("kind", `String "record");
           ( "entries",
             `List
               (List.filter_map
                  (fun ((lid : Longident.t loc), fexpr) ->
                    match example_of_expr fexpr with
                    | Some v ->
                      Some (`List [ `String (flatten_longident lid.txt); v ])
                    | None -> None)
                  fields) ) ])
  | _ -> None

(* `[name, exampleValue]` pairs matching Model.exampleEntriesSchema. *)
let record_entries (e : expression) : Yojson.Safe.t list =
  match e.pexp_desc with
  | Pexp_record (fields, _) ->
    List.filter_map
      (fun ((lid : Longident.t loc), fexpr) ->
        match example_of_expr fexpr with
        | Some v -> Some (`List [ `String (flatten_longident lid.txt); v ])
        | None -> None)
      fields
  | _ -> []

(* A `Ctor({..})` / `Ctor` → (element name, value entries). *)
let element_of_constructor (e : expression) : (string * Yojson.Safe.t list) option =
  match e.pexp_desc with
  | Pexp_construct ({ txt; _ }, payload) ->
    let name = flatten_longident txt in
    let values =
      match payload with Some rec_expr -> record_entries rec_expr | None -> []
    in
    Some (name, values)
  | _ -> None

(* ── collect named applies anywhere in a test body ──────────────────────── *)

let step_names =
  [ "givenEvents"; "givenEvent"; "whenCmd"; "whenCommand"; "whenInput";
    "thenEvent"; "thenError"; "thenState"; "thenCommand"; "thenSideEffect" ]

let rec collect_applies (e : expression) (acc : (string * expression list) list) :
    (string * expression list) list =
  match e.pexp_desc with
  | Pexp_apply ({ pexp_desc = Pexp_ident { txt; _ }; _ }, args) ->
    let name = flatten_longident txt in
    let arg_exprs = List.map snd args in
    let acc =
      if List.mem name step_names then (name, arg_exprs) :: acc else acc
    in
    List.fold_left (fun a ae -> collect_applies ae a) acc arg_exprs
  | Pexp_construct (_, Some inner) -> collect_applies inner acc
  | Pexp_array els ->
    List.fold_left (fun a ae -> collect_applies ae a) acc els
  | _ -> acc

let last = function [] -> None | xs -> Some (List.nth xs (List.length xs - 1))

let step_json ~kind ~element ~values : Yojson.Safe.t =
  `Assoc
    [ ("kind", `String kind); ("element", `String element); ("values", `List values) ]

(* Build the given / when / then arrays for one test body. *)
let extract_steps (body : expression) :
    Yojson.Safe.t list * Yojson.Safe.t list * Yojson.Safe.t list =
  let calls = collect_applies body [] in
  let find names =
    List.find_opt (fun (n, _) -> List.mem n names) calls
  in
  let given =
    match find [ "givenEvents"; "givenEvent" ] with
    | Some (_, args) -> (
      match last args with
      | Some { pexp_desc = Pexp_array els; _ } ->
        List.filter_map
          (fun el ->
            match element_of_constructor el with
            | Some (element, values) -> Some (step_json ~kind:"event" ~element ~values)
            | None -> None)
          els
      | Some single -> (
        match element_of_constructor single with
        | Some (element, values) -> [ step_json ~kind:"event" ~element ~values ]
        | None -> [])
      | None -> [])
    | None -> []
  in
  let when_ =
    match find [ "whenCmd"; "whenCommand"; "whenInput" ] with
    | Some (name, args) -> (
      let kind = if String.equal name "whenInput" then "input" else "command" in
      match last args with
      | Some payload -> (
        match element_of_constructor payload with
        | Some (element, values) -> [ step_json ~kind ~element ~values ]
        | None -> [])
      | None -> [])
    | None -> []
  in
  let then_ =
    match find [ "thenEvent"; "thenError"; "thenState"; "thenCommand"; "thenSideEffect" ] with
    | Some (name, args) -> (
      match last args with
      | Some payload -> (
        match name with
        | "thenState" ->
          [ step_json ~kind:"state" ~element:"state" ~values:(record_entries payload) ]
        | _ -> (
          let kind =
            match name with
            | "thenError" -> "error"
            | "thenCommand" -> "command"
            | "thenSideEffect" -> "sideEffect"
            | _ -> "event"
          in
          match element_of_constructor payload with
          | Some (element, values) -> [ step_json ~kind ~element ~values ]
          | None -> []))
      | None -> [])
    | None -> []
  in
  (given, when_, then_)

(* ── spec-id comments (recovered from source text) ──────────────────────── *)

let read_spec_ids (fname : string) : (int * string) list =
  try
    let ic = open_in fname in
    let rec loop n acc =
      match input_line ic with
      | line ->
        let trimmed = String.trim line in
        let prefix = "// spec-id:" in
        let acc =
          if String.length trimmed >= String.length prefix
             && String.equal (String.sub trimmed 0 (String.length prefix)) prefix
          then
            let id =
              String.trim
                (String.sub trimmed (String.length prefix)
                   (String.length trimmed - String.length prefix))
            in
            (n, id) :: acc
          else acc
        in
        loop (n + 1) acc
      | exception End_of_file ->
        close_in ic;
        List.rev acc
    in
    loop 1 []
  with _ -> []

let spec_id_for (line : int) (ids : (int * string) list) : string option =
  List.fold_left
    (fun best (n, id) ->
      if n < line then
        match best with
        | Some (bn, _) when bn >= n -> best
        | _ -> Some (n, id)
      else best)
    None ids
  |> Option.map snd

(* ── collect the `test(...)` calls inside a `describe` body ──────────────── *)

let string_of_expr (e : expression) : string option =
  match e.pexp_desc with
  | Pexp_constant (Pconst_string (s, _, _)) -> Some s
  | _ -> None

(* ReScript v12 wraps every (uncurried) lambda as [Function$(inner_fun)] — a
   `Pexp_construct (Lident "Function$", Some inner)` around the real `Pexp_fun`
   (see `TypeAnnotationInjection.annotate_function`). `describe`/`test` callbacks
   therefore present as a construct, not a `Pexp_fun`, so the function body must
   be reached through this wrapper. (Hand-built test ASTs skip the wrapper, which
   is why the unit test never exercised this.) *)
let rec fun_body (e : expression) : expression option =
  match e.pexp_desc with
  | Pexp_construct ({ txt = Lident "Function$"; _ }, Some inner) -> fun_body inner
  | Pexp_fun (_, _, _, body) -> Some body
  | _ -> None

let rec collect_tests (e : expression)
    (acc : (Location.t * string * expression) list) :
    (Location.t * string * expression) list =
  match e.pexp_desc with
  | Pexp_sequence (a, b) -> collect_tests b (collect_tests a acc)
  | Pexp_apply ({ pexp_desc = Pexp_ident { txt = Lident "test"; _ }; _ }, args) -> (
    let arg_exprs = List.map snd args in
    match arg_exprs with
    | title_e :: fn :: _ -> (
      match (string_of_expr title_e, fun_body fn) with
      | Some title, Some test_body -> (e.pexp_loc, title, test_body) :: acc
      | _ -> acc)
    | _ -> acc)
  | Pexp_let (_, _, cont) -> collect_tests cont acc
  | _ -> acc

(* A top-level `describe("Spec", () => { ... })` → (specName, tests). *)
let describe_of_item (item : structure_item) :
    (string * (Location.t * string * expression) list) option =
  match item.pstr_desc with
  | Pstr_eval
      ( { pexp_desc =
            Pexp_apply
              ( { pexp_desc = Pexp_ident { txt = Lident "describe"; _ }; _ },
                args );
          _ },
        _ ) -> (
    match List.map snd args with
    | name_e :: fn :: _ -> (
      match (string_of_expr name_e, fun_body fn) with
      | Some spec_name, Some body ->
        Some (spec_name, List.rev (collect_tests body []))
      | _ -> None)
    | _ -> None)
  | _ -> None

let gwt_fragment_json ~fname (str : structure) : Yojson.Safe.t option =
  let spec_ids = read_spec_ids fname in
  let describes = List.filter_map describe_of_item str in
  match describes with
  | [] -> None
  | _ ->
    let spec_name =
      match describes with (n, _) :: _ -> n | [] -> filename_stem fname
    in
    let scenarios =
      List.concat_map
        (fun (_, tests) ->
          List.map
            (fun (loc, title, body) ->
              let spec_id =
                match spec_id_for loc.loc_start.pos_lnum spec_ids with
                | Some id -> id
                | None -> ""
              in
              let given, when_, then_ = extract_steps body in
              `Assoc
                [ ("specId", `String spec_id);
                  ("title", `String title);
                  ("given", `List given);
                  ("when", `List when_);
                  ("then", `List then_) ])
            tests)
        describes
    in
    Some
      (`Assoc
         [ ("specName", `String spec_name);
           ("stem", `String (filename_stem fname));
           ("file", `String (repo_relative fname));
           ("scenarios", `List scenarios) ])

let gwt_sidecar_path (fname : string) : string =
  if Filename.check_suffix fname ".res" then
    Filename.chop_suffix fname ".res" ^ ".gwt.json"
  else fname ^ ".gwt.json"

(* Public entry — called from the dispatcher for @@reventless.gwt files with
   the original test structure (before the GWT include/open injection). *)
let maybe_emit_gwt ~fname (str : structure) : unit =
  if is_enabled () && fname <> "" then
    try
      match gwt_fragment_json ~fname str with
      | Some json ->
        let path = gwt_sidecar_path fname in
        let oc = open_out path in
        output_string oc (Yojson.Safe.pretty_to_string json);
        output_char oc '\n';
        close_out oc
      | None -> ()
    with exn ->
      Printf.eprintf "[reventless-ppx] gwt sidecar emit failed for %s: %s\n"
        fname (Printexc.to_string exn)
