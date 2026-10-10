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
   assembler can decode it with `Model.fieldFromJson` directly. The `let`
   config values (see `config_keys`) are captured too, as source text.

   This module reads the spec body *before* `DcbTagInference` rewrites the
   field annotations into `@s.matches(...)`, so the original `@partitionTag` /
   `@noDcbTag` / `@dcbTag` / `@id` / `@index` intent is still visible. *)

open Ppxlib

(* ── Gating ─────────────────────────────────────────────────────────────── *)

let is_enabled () =
  match Sys.getenv_opt "REVENTLESS_EMIT_SIDECAR" with
  | Some ("1" | "true" | "TRUE") -> true
  | _ -> false

(* ── Small AST helpers ──────────────────────────────────────────────────── *)

let has_attr (name : string) (attrs : attributes) : bool =
  List.exists (fun (a : attribute) -> String.equal a.attr_name.txt name) attrs

(* ── source text ────────────────────────────────────────────────────────── *)

(* The whole source file, or None when it cannot be read. One read serves every
   cut a sidecar makes from it: annotation arguments, scenario-id markers
   (comments, which ppxlib drops) and the values recorded as code. *)
let read_source (fname : string) : string option =
  try
    let ic = open_in_bin fname in
    let len = in_channel_length ic in
    let text = really_input_string ic len in
    close_in ic;
    Some text
  with _ -> None

(* The byte offset of a position in [src]. The ReScript parser gives a line's start
   (pos_bol) in bytes but counts the column (pos_cnum - pos_bol) in UTF-16 code
   units, so after a non-ASCII character on the same line pos_cnum falls short of
   the byte: by one for `é`, two for `—` or an emoji. The column is walked again
   over the line's bytes. *)
let byte_offset (src : string) (p : Lexing.position) : int =
  let len = String.length src in
  let rec go i units =
    if units <= 0 || i >= len || src.[i] = '\n' then i
    else
      let c = Char.code src.[i] in
      let bytes, u =
        if c < 0x80 then (1, 1) else if c < 0xE0 then (2, 1) else if c < 0xF0 then (3, 1) else (4, 2)
      in
      go (i + bytes) (units - u)
  in
  if p.pos_bol < 0 || p.pos_bol > len || p.pos_cnum < p.pos_bol then p.pos_cnum
  else go p.pos_bol (p.pos_cnum - p.pos_bol)

(* The byte span of an attribute's argument, `@name(<here>)`: its payload's
   first item to its last. None for a structure payload with no items, or any
   other payload shape. The source reader cuts with this too. *)
let attribute_args_span ~(src : string) (a : attribute) : (int * int) option =
  match a.attr_payload with
  | PStr (first :: _ as items) ->
    let last = List.nth items (List.length items - 1) in
    Some (byte_offset src first.pstr_loc.loc_start, byte_offset src last.pstr_loc.loc_end)
  | _ -> None

let attribute_args ~(src : string) (a : attribute) : string option =
  match attribute_args_span ~src a with
  | Some (s, e) when s >= 0 && e >= s && e <= String.length src -> Some (String.sub src s (e - s))
  | _ -> None

let is_res_hint (a : attribute) =
  let n = a.attr_name.txt in
  String.length n >= 4 && String.equal (String.sub n 0 4) "res."

(* A field annotation as the sidecar writes it: its name, or `{name, args}` when
   it has an argument. `res.*` are the parser's hints (`res.doc`'s payload is a
   whole doc comment), so they stay names. Without the source, names only. *)
let annotation_json ?src (a : attribute) : Yojson.Safe.t =
  let name = a.attr_name.txt in
  match src with
  | Some src when not (is_res_hint a) -> (
    match attribute_args ~src a with
    | Some args -> `Assoc [ ("name", `String name); ("args", `String args) ]
    | None -> `String name)
  | _ -> `String name

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
let dcb_role_json ~dcb_context ?(nested = false) ~(name : string) ~(ct : core_type)
    ~(attrs : attributes) () : Yojson.Safe.t =
  let role s = `Assoc [ ("role", `String s) ] in
  (* A typed id is tagged by its identity's key, which only the runtime schema
     knows. The sidecar has the syntax alone, so it states the key the module
     name gives by convention — inside the existing role vocabulary, which older
     readers decode strictly. *)
  let identity_key =
    let m = match Util.identity_module ct with
      | Some m -> Some m
      | None -> Option.bind (Util.array_element ct) Util.identity_module
    in
    Option.bind m Util.conventional_identity_key
  in
  (* A record a DCB-context type holds is tagged by `DcbTag.nestedRecordTags`,
     but only `ReferenceInference` puts tag metadata on a record's fields: the
     auto-`*Id`, typed-id and explicit `@dcbTag` passes rewrite variant
     constructors alone. So a nested field is a tag exactly when it is a `@ref`. *)
  if nested then
    if not (ReferenceInference.has_ref_field_attr attrs) then role "noTag"
    else if has_attr "noDcbTag" attrs then role "suppressed"
    else
      let key =
        match DcbTagInference.get_explicit_dcb_tag_key attrs, identity_key with
        | Some k, _ | None, Some k -> k
        | None, None when is_array_string_type ct && ReferenceInference.ends_with_ids name ->
          Util.drop_trailing_s name
        | None, None -> name
      in
      `Assoc [ ("role", `String "customKey"); ("key", `String key) ]
  else if not dcb_context then role "noTag"
  else if has_attr "partitionTag" attrs then
    (match identity_key with
     | Some key -> `Assoc [ ("role", `String "partition"); ("key", `String key) ]
     | None -> role "partition")
  else if has_attr "noDcbTag" attrs then role "suppressed"
  else if has_attr "dcbTag" attrs then
    let key =
      match DcbTagInference.get_explicit_dcb_tag_key attrs, identity_key with
      | Some k, _ | None, Some k -> k
      | None, None -> name
    in
    `Assoc [ ("role", `String "customKey"); ("key", `String key) ]
  else if identity_key <> None then
    `Assoc [ ("role", `String "customKey"); ("key", `String (Option.get identity_key)) ]
  else if is_array_string_type ct && ends_with name "Ids" then
    role "autoStringForKey"
  else if is_string_type ct && ends_with name "Id" then role "autoString"
  else role "noTag"

(* ── label_declaration → Model.field JSON ───────────────────────────────── *)

(* `@ref("Entity")` / `@ref("Plugin.Entity")` → its target. Only fields that
   carry one get the key, so sidecars without references are unchanged. *)
let ref_json (attrs : attributes) : (string * Yojson.Safe.t) list =
  match ReferenceInference.get_ref_target attrs with
  | Some (entity, plugin) ->
    [ ( "ref",
        `Assoc
          [ ("entity", `String entity);
            ("plugin", match plugin with Some p -> `String p | None -> `Null) ] ) ]
  | None -> []

let field_json ?src ~dcb_context ?(nested = false) (ld : label_declaration) : Yojson.Safe.t =
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
    ([ ("name", `String name);
       ("kind", kind_of_type ld.pld_type);
       ("isId", `Bool is_id);
       ("isIndex", `Bool is_index);
       ("isCompositeTag", `Bool is_composite);
       ("dcbRole", dcb_role_json ~dcb_context ~nested ~name ~ct:ld.pld_type ~attrs ());
       ("example", `Null);
       ("annotations", `List (List.map (annotation_json ?src) attrs)) ]
     @ ref_json attrs)

(* ── constructor / record → element JSON ────────────────────────────────── *)

let fields_of_args ?src ~dcb_context (args : constructor_arguments) :
    Yojson.Safe.t list =
  match args with
  | Pcstr_record lds -> List.map (field_json ?src ~dcb_context) lds
  | Pcstr_tuple _ -> [] (* payload-less or positional — no named fields *)

(* ── nested records ─────────────────────────────────────────────────────── *)

(* The local type a field holds as `T`, `option<T>`, `array<T>` or
   `array<option<T>>` — the shapes `DcbTag.nestedRecordProperties` unwraps. *)
let held_type_name (ct : core_type) : string option =
  let unwrap_option (ct : core_type) =
    match ct.ptyp_desc with
    | Ptyp_constr ({ txt = Lident "option"; _ }, [ t ]) -> t
    | _ -> ct
  in
  let ct = unwrap_option ct in
  let ct =
    match ct.ptyp_desc with
    | Ptyp_constr ({ txt = Lident ("array" | "list"); _ }, [ t ]) -> unwrap_option t
    | _ -> ct
  in
  match ct.ptyp_desc with
  | Ptyp_constr ({ txt = Lident n; _ }, []) -> Some n
  | _ -> None

(* The names of the types a DCB-context `@schema` type's fields hold. A record
   among them is nested: its tagged fields are the decision's tags too. *)
let nested_type_names (tds : type_declaration list) : string list =
  let labels (td : type_declaration) =
    match td.ptype_kind with
    | Ptype_variant ctors ->
      List.concat_map
        (fun (c : constructor_declaration) ->
          match c.pcd_args with Pcstr_record lds -> lds | Pcstr_tuple _ -> [])
        ctors
    | Ptype_record lds -> lds
    | _ -> []
  in
  tds
  |> List.filter (fun td -> is_dcb_context td.ptype_name.txt)
  |> List.concat_map labels
  |> List.filter_map (fun (ld : label_declaration) -> held_type_name ld.pld_type)

let element_json ~name ~fields : Yojson.Safe.t =
  `Assoc
    [ ("name", `String name);
      ("payloadless", `Bool (fields = []));
      ("fields", `List fields) ]

(* A `@schema type` declaration → one "types" entry. Variants expand to one
   element per constructor; records collapse to a single element named after
   the type. Abstract / alias types are skipped (returns None). *)
let type_entry ?src ?(nested = []) (td : type_declaration) : Yojson.Safe.t option =
  let type_name = td.ptype_name.txt in
  let dcb_context = is_dcb_context type_name in
  let nested = (not dcb_context) && List.mem type_name nested in
  match td.ptype_kind with
  | Ptype_variant ctors ->
    let elements =
      List.map
        (fun (c : constructor_declaration) ->
          let fields = fields_of_args ?src ~dcb_context c.pcd_args in
          element_json ~name:c.pcd_name.txt ~fields)
        ctors
    in
    Some
      (`Assoc
         [ ("typeName", `String type_name);
           ("shape", `String "variant");
           ("elements", `List elements) ])
  | Ptype_record lds ->
    let fields = List.map (field_json ?src ~dcb_context ~nested) lds in
    Some
      (`Assoc
         [ ("typeName", `String type_name);
           ("shape", `String "record");
           ("elements", `List [ element_json ~name:type_name ~fields ]) ])
  | _ -> None

(* The source text an expression was parsed from, cut by its byte offsets. None
   when there is no source, or the location is one the parser did not set or
   that does not fit the file — the value is then dropped, as before code
   values existed. *)
let text_at ?src (loc : Location.t) : string option =
  match src with
  | None -> None
  | Some text ->
    let a = byte_offset text loc.loc_start and b = byte_offset text loc.loc_end in
    if a >= 0 && b > a && b <= String.length text then Some (String.sub text a (b - a))
    else None

let source_text ?src (e : expression) : string option = text_at ?src e.pexp_loc

let strip_poly (ct : core_type) : core_type =
  match ct.ptyp_desc with Ptyp_poly ([], t) -> t | _ -> ct

(* A binding of a single name → (name, annotation, value). The annotation sits on
   the pattern (`let x: t = e`), on the expression (`let x = (e: t)`), or on both
   — the parsers disagree on which, so all three are read. *)
let named_binding (vb : value_binding) :
    (string * core_type option * expression) option =
  let unconstrain (e : expression) =
    match e.pexp_desc with
    | Pexp_constraint (inner, ct) -> (inner, Some ct)
    | _ -> (e, None)
  in
  match vb.pvb_pat.ppat_desc with
  | Ppat_var { txt; _ } ->
    let e, ct = unconstrain vb.pvb_expr in
    Some (txt, ct, e)
  | Ppat_constraint ({ ppat_desc = Ppat_var { txt; _ }; _ }, ct) ->
    let e, _ = unconstrain vb.pvb_expr in
    Some (txt, Some (strip_poly ct), e)
  | _ -> None

(* ── config constants ─────────────────────────────────────────────────── *)

let config_keys =
  [ "targetName"; "maxRetries"; "heartbeatInterval"; "externalSystem"; "sourceNames";
    "capabilityNeeds"; "traits" ]

(* A string literal as ReScript writes it. The ReScript parser keeps a "…"
   string's escapes as written (delimiter "*j"), so quoting it again restores the
   literal; content from anywhere else is escaped. *)
let string_literal_text (s : string) (delim : string option) : string =
  match delim with
  | Some "*j" -> "\"" ^ s ^ "\""
  | _ -> Yojson.Safe.to_string (`String s)

(* A config value as the source writes it: a literal (the file's own spelling
   when at hand), a name, a payload-less constructor, `Some` of one (recorded as
   the value), or an array of them. None for anything else, and for `None`: an
   absent value is no entry, so an outbound slice without a target still reads
   as fire-and-forget. *)
let rec config_value ?src (e : expression) : string option =
  match e.pexp_desc with
  | Pexp_constraint (inner, _) -> config_value ?src inner
  | Pexp_constant (Pconst_integer (s, _) | Pconst_float (s, _)) -> Some s
  | Pexp_constant (Pconst_string (s, _, delim)) -> (
    match source_text ?src e with
    | Some t when String.length t >= 2 && (t.[0] = '"' || t.[0] = '`') -> Some t
    | _ -> Some (string_literal_text s delim))
  | Pexp_construct ({ txt = Lident "None"; _ }, None) -> None
  | Pexp_construct ({ txt = Lident "Some"; _ }, Some inner) -> config_value ?src inner
  | Pexp_construct ({ txt = (Lident _ | Ldot _) as lid; _ }, None)
  | Pexp_ident { txt = (Lident _ | Ldot _) as lid; _ } -> Some (flatten_longident lid)
  | Pexp_array els ->
    let items = List.map (config_value ?src) els in
    if List.for_all Option.is_some items then
      Some ("[" ^ String.concat ", " (List.filter_map Fun.id items) ^ "]")
    else None
  | _ -> None

let config_entries ?src (str : structure) : Yojson.Safe.t list =
  List.concat_map
    (fun (item : structure_item) ->
      match item.pstr_desc with
      | Pstr_value (_, vbs) ->
        List.filter_map
          (fun (vb : value_binding) ->
            match named_binding vb with
            | Some (name, _, e) when List.mem name config_keys ->
              Option.map
                (fun v -> `Assoc [ ("key", `String name); ("value", `String v) ])
                (config_value ?src e)
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

let fragment_json ?src ~spec_name ~fname (body : structure) : Yojson.Safe.t =
  let schema_types =
    List.concat_map
      (fun (item : structure_item) ->
        match item.pstr_desc with
        | Pstr_type (_, tds) -> List.filter is_schema_type tds
        | _ -> [])
      body
  in
  let nested = nested_type_names schema_types in
  let types = List.filter_map (type_entry ?src ~nested) schema_types in
  `Assoc
    [ ("specName", `String spec_name);
      ("stem", `String (filename_stem fname));
      ("file", `String (repo_relative fname));
      ("types", `List types);
      ("config", `List (config_entries ?src body)) ]

let sidecar_path (fname : string) : string =
  if Filename.check_suffix fname ".res" then
    Filename.chop_suffix fname ".res" ^ ".model.json"
  else fname ^ ".model.json"

(* Best-effort: never fail the compile if the write throws. *)
let write_sidecar ~spec_name ~fname (body : structure) : unit =
  try
    let json = fragment_json ?src:(read_source fname) ~spec_name ~fname body in
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
   Automation wiring — emit <Stem>.wiring.json for a `@@reventless.automation`
   body: each mapping of `let mappings`, in its order, with the slice it feeds
   and the source it reads. A source declared in the file carries its events;
   one declared elsewhere is a `ref` to resolve through that module's sidecar.
   Not `.model.json`: every reader of those takes the file for a component.
   ════════════════════════════════════════════════════════════════════════ *)

let schema_types_of (str : structure) : type_declaration list =
  List.concat_map
    (fun (item : structure_item) ->
      match item.pstr_desc with
      | Pstr_type (_, tds) -> List.filter is_schema_type tds
      | _ -> [])
    str

let module_path (me : module_expr) : string option =
  match me.pmod_desc with
  | Pmod_ident { txt; _ } -> ( try Some (flatten_longident txt) with _ -> None)
  | _ -> None

(* `F(A, B, C)` → (F, [A; B; C]). *)
let rec functor_args (me : module_expr) : module_expr * module_expr list =
  match me.pmod_desc with
  | Pmod_apply (f, a) ->
    let head, args = functor_args f in
    (head, args @ [ a ])
  | Pmod_constraint (inner, _) -> functor_args inner
  | _ -> (me, [])

let rec structure_of (me : module_expr) : structure option =
  match me.pmod_desc with
  | Pmod_structure str -> Some str
  | Pmod_constraint (inner, _) -> structure_of inner
  | _ -> None

let source_json ?src ~(inline : (string * structure) list) (path : string) : Yojson.Safe.t =
  match List.assoc_opt path inline with
  | None -> `Assoc [ ("ref", `String path) ]
  | Some str ->
    let schema = schema_types_of str in
    let nested = nested_type_names schema in
    let events, others = List.partition (fun td -> String.equal td.ptype_name.txt "event") schema in
    let source_name =
      List.find_map
        (fun (item : structure_item) ->
          match item.pstr_desc with
          | Pstr_value (_, vbs) ->
            List.find_map
              (fun vb ->
                match named_binding vb with
                | Some ("name", _, e) -> config_value ?src e
                | _ -> None)
              vbs
          | _ -> None)
        str
    in
    `Assoc
      [ ("module", `String path);
        ("sourceName", match source_name with Some s -> `String s | None -> `Null);
        ( "events",
          match events with
          | td :: _ -> Option.value (type_entry ?src ~nested td) ~default:`Null
          | [] -> `Null );
        ("types", `List (List.filter_map (type_entry ?src ~nested) others)) ]

let wiring_fragment_json ?src ~spec_name ~fname (body : structure) : Yojson.Safe.t =
  let modules =
    List.filter_map
      (fun (item : structure_item) ->
        match item.pstr_desc with
        | Pstr_module { pmb_name = { txt = Some name; _ }; pmb_expr; _ } -> Some (name, pmb_expr)
        | _ -> None)
      body
  in
  let inline = List.filter_map (fun (n, me) -> Option.map (fun s -> (n, s)) (structure_of me)) modules in
  (* `module F = Mapping.Make(Source, Target, {…})` *)
  let made =
    List.filter_map
      (fun (n, me) ->
        match functor_args me with
        | head, (_ :: _ as args)
          when (match module_path head with
                | Some p -> String.equal p "Make" || ends_with p ".Make"
                | None -> false) ->
          Some (n, args)
        | _ -> None)
      modules
  in
  let mapping_names =
    let rec packed (e : expression) =
      match e.pexp_desc with
      | Pexp_pack me -> module_path me
      | Pexp_constraint (inner, _) -> packed inner
      | _ -> None
    in
    List.concat_map
      (fun (item : structure_item) ->
        match item.pstr_desc with
        | Pstr_value (_, vbs) ->
          List.concat_map
            (fun vb ->
              match named_binding vb with
              | Some ("mappings", _, { pexp_desc = Pexp_array els; _ }) -> List.filter_map packed els
              | _ -> [])
            vbs
        | _ -> [])
      body
  in
  let path_json = function Some p -> `String p | None -> `Null in
  let mapping_json name =
    match List.assoc_opt name made with
    | Some args ->
      let arg i = Option.bind (List.nth_opt args i) module_path in
      `Assoc
        [ ("module", `String name);
          ("target", path_json (arg 1));
          ("source", match arg 0 with Some p -> source_json ?src ~inline p | None -> `Null) ]
    | None -> `Assoc [ ("module", `String name); ("target", `Null); ("source", `Null) ]
  in
  `Assoc
    [ ("specName", `String spec_name);
      ("stem", `String (filename_stem fname));
      ("file", `String (repo_relative fname));
      ("mappings", `List (List.map mapping_json mapping_names)) ]

let wiring_sidecar_path (fname : string) : string =
  if Filename.check_suffix fname ".res" then
    Filename.chop_suffix fname ".res" ^ ".wiring.json"
  else fname ^ ".wiring.json"

(* Public entry — called from the dispatcher for a `@@reventless.automation`
   body, captured before the DCB-tag passes rewrite its sources' annotations. *)
let maybe_emit_wiring ~spec_name ~fname (body : structure) : unit =
  if is_enabled () && fname <> "" then
    try
      let json = wiring_fragment_json ?src:(read_source fname) ~spec_name ~fname body in
      let oc = open_out (wiring_sidecar_path fname) in
      output_string oc (Yojson.Safe.pretty_to_string json);
      output_char oc '\n';
      close_out oc
    with exn ->
      Printf.eprintf "[reventless-ppx] wiring sidecar emit failed for %s: %s\n" fname
        (Printexc.to_string exn)

(* ════════════════════════════════════════════════════════════════════════
   GWT extraction (Plan 06 Phase 2) — emit <Stem>.gwt.json for @@reventless.gwt
   files whose `test` bodies use the inline-literal shape the forward emitter
   writes:

     describe("Spec", () => {
       // scenario-id: <id>        (or the older `// spec-id: <id>`)
       test("title", () =>
         givenEvents([E({..}), ..])
         ->whenCmd(C({..}))            // or ->whenInput(..)
         ->thenEvent(E({..}))          // or ->thenError(E) / ->thenState({..})
       )
     })

   The body is a nest of applies (and pipes); we walk it in written order and
   read each step by its verb. Every scenario records its `steps`
   (`{group, verb, kind, element, values, via?}`) and, from the same walk, the
   lossy `given` / `when` / `then` groups older readers take. The file records
   its `componentKind`. The `// scenario-id:` lives in a comment (ppxlib drops
   comments) so it is recovered from the source text by line, correlated to
   each `test(...)` / `testSync(...)` location.
   ════════════════════════════════════════════════════════════════════════ *)

(* ── source text (read once per sidecar) ─────────────────────────────── *)


(* ── example values from expressions (→ Model.exampleValue JSON) ──────── *)

let rec example_of_expr ?src (e : expression) : Yojson.Safe.t option =
  match e.pexp_desc with
  | Pexp_constant (Pconst_string (s, _, _)) ->
    Some (`Assoc [ ("kind", `String "string"); ("value", `String s) ])
  | Pexp_constant (Pconst_integer (s, _)) -> (
    match int_of_string_opt s with
    | Some i -> Some (`Assoc [ ("kind", `String "int"); ("value", `Int i) ])
    | None -> code_of_expr ?src e)
  | Pexp_constant (Pconst_float (s, _)) -> (
    match float_of_string_opt s with
    | Some f -> Some (`Assoc [ ("kind", `String "float"); ("value", `Float f) ])
    | None -> code_of_expr ?src e)
  | Pexp_construct ({ txt = Lident "true"; _ }, None) ->
    Some (`Assoc [ ("kind", `String "bool"); ("value", `Bool true) ])
  | Pexp_construct ({ txt = Lident "false"; _ }, None) ->
    Some (`Assoc [ ("kind", `String "bool"); ("value", `Bool false) ])
  | Pexp_construct ({ txt = Lident "None"; _ }, None) ->
    Some (`Assoc [ ("kind", `String "null") ])
  | Pexp_construct ({ txt = Lident "Some"; _ }, Some inner) -> example_of_expr ?src inner
  (* A typed id made from a literal — `oid("o1")`, `OrderId.make("o1")`. Its
     value is the string: a scenario relates its given events to its command by
     comparing ids, and a test that types its ids must not read as one whose ids
     are unknown. The function is kept beside it so a writer can reproduce the
     call rather than a bare string, which would not compile. *)
  | Pexp_apply
      ( { pexp_desc = Pexp_ident { txt = fn; _ }; _ },
        [ (Nolabel, { pexp_desc = Pexp_constant (Pconst_string (s, _, _)); _ }) ] ) ->
    Some
      (`Assoc
         [ ("kind", `String "string");
           ("value", `String s);
           ("constructor", `String (flatten_longident fn)) ])
  (* A payload-less constructor — `Listed`, `Customers.Active`. Recorded as its
     own kind rather than as a string: the two are different ReScript source, and
     a consumer that renders `"Listed"` where the author wrote `Listed` produces
     a record literal that does not compile. The name is kept as written, prefix
     and all, so a reader can take the last segment and a writer can reproduce
     the qualification. This is the value a lifecycle field carries, so dropping
     it (as this walk used to) makes a projection scenario unreadable. *)
  | Pexp_construct ({ txt; _ }, None) ->
    Some
      (`Assoc
         [ ("kind", `String "enum"); ("value", `String (flatten_longident txt)) ])
  (* A named value — `o1`, `dockLine`, `OrderingExamples.dockLine`. Recorded as
     the name, not resolved: what it points to is the reader's to decide, and the
     name is what a writer puts back. Dropping it made a list of named lines read
     as an empty list. *)
  | Pexp_ident { txt = (Lident _ | Ldot _) as lid; _ } ->
    Some (`Assoc [ ("kind", `String "ref"); ("name", `String (flatten_longident lid)) ])
  | Pexp_array els ->
    Some
      (`Assoc
         [ ("kind", `String "list");
           ("items", `List (List.filter_map (example_of_expr ?src) els)) ])
  | Pexp_record (fields, _) ->
    Some
      (`Assoc
         [ ("kind", `String "record");
           ( "entries",
             `List
               (List.filter_map
                  (fun ((lid : Longident.t loc), fexpr) ->
                    match example_of_expr ?src fexpr with
                    | Some v ->
                      Some (`List [ `String (flatten_longident lid.txt); v ])
                    | None -> None)
                  fields) ) ])
  | _ -> code_of_expr ?src e

(* Anything the walk above cannot read — `eur(4500.0)`,
   `Reventless.Money.make(~amount=1000.0, ~currency=EUR)` — is recorded as the
   source text it was written as, so a field the test states never reads as one
   it leaves out. The text comes from the file, never from printing the AST:
   the printer writes OCaml syntax, not ReScript. *)
and code_of_expr ?src (e : expression) : Yojson.Safe.t option =
  match source_text ?src e with
  | Some text -> Some (`Assoc [ ("kind", `String "code"); ("value", `String text) ])
  | None -> None

(* `[name, exampleValue]` pairs matching Model.exampleEntriesSchema. *)
let record_entries ?src (e : expression) : Yojson.Safe.t list =
  match e.pexp_desc with
  | Pexp_record (fields, _) ->
    List.filter_map
      (fun ((lid : Longident.t loc), fexpr) ->
        match example_of_expr ?src fexpr with
        | Some v -> Some (`List [ `String (flatten_longident lid.txt); v ])
        | None -> None)
      fields
  | _ -> []

(* A `Ctor({..})` / `Ctor` → (element name, value entries). *)
let element_of_constructor ?src (e : expression) :
    (string * Yojson.Safe.t list) option =
  match e.pexp_desc with
  | Pexp_construct ({ txt; _ }, payload) ->
    let name = flatten_longident txt in
    let values =
      match payload with Some rec_expr -> record_entries ?src rec_expr | None -> []
    in
    Some (name, values)
  | _ -> None

(* ── the steps of a test body, in written order ─────────────────────────── *)

(* The verbs the scenario walk records. A verb not listed is still a step to
   the ordered walk below (it keeps the chain together) but records nothing. *)
let step_names =
  [ "givenEvents"; "givenEvent"; "givenTodo"; "givenCapabilities";
    "whenCmd"; "whenCommand"; "whenInput"; "whenReceived"; "whenEvent"; "whenEvents";
    "whenCollect"; "whenResolve"; "whenSweep"; "whenReacts"; "whenPublishedThrough";
    "whenExtensionReacts"; "whenProcess"; "whenTranslated"; "whenTranslateMocked";
    "whenTranslateRetrying"; "whenExhausted"; "andThenEvents";
    "thenEvent"; "thenEvents"; "thenError"; "thenState"; "thenStates";
    "thenStateWithId"; "thenStatesWithId"; "thenNoState"; "thenViewState"; "thenViewStates";
    "thenCommand"; "thenCommands"; "thenIssuesCommand"; "thenIssuesCommands";
    "thenNoCommand"; "thenIssuesNoCommand"; "thenSideEffect"; "thenNoEvent"; "thenRefused";
    "thenTodos"; "thenScenarioTodos"; "thenResolved"; "thenTranslateError";
    "thenNotUnderstood"; "thenRefusedInput"; "thenSent"; "thenNothingSent"; "thenOutbound";
    "thenOutboundNothing"; "thenTodoStatus"; "thenRetryRecorded"; "thenPublicEvent";
    "thenPublicEvents" ]

(* A GWT module built by a functor is called qualified — `CustomerGwt.thenState`,
   `Auto.thenIssuesCommand` — and the step is the same step, so the last segment
   is what identifies it. *)
let step_name_of (lid : Longident.t) : string =
  match Longident.flatten_exn lid with
  | [] -> ""
  | segments -> List.nth segments (List.length segments - 1)
  | exception _ -> ""

(* The module a qualified step is called through: `Auto` in
   `Auto.thenIssuesCommand`. *)
let step_via (lid : Longident.t) : string option =
  match Longident.flatten_exn lid with
  | ([] | [ _ ]) -> None
  | segments ->
    let n = List.length segments in
    Some (String.concat "." (List.filteri (fun i _ -> i < n - 1) segments))
  | exception _ -> None

(* A step is any `given…` / `when…` / `then…` call, not only the verbs above:
   a DSL has its own (`whenIncomingEvent`), and a reader reports what is
   written. *)
let is_verb (lid : Longident.t) =
  let name = step_name_of lid in
  List.mem name step_names
  || List.exists
       (fun prefix ->
         let lp = String.length prefix in
         String.length name > lp
         && String.equal (String.sub name 0 lp) prefix
         && Char.uppercase_ascii name.[lp] = name.[lp]
         && Char.lowercase_ascii name.[lp] <> name.[lp])
       [ "given"; "when"; "then" ]

let rec holds_step (e : expression) =
  match e.pexp_desc with
  | Pexp_apply ({ pexp_desc = Pexp_ident { txt; _ }; _ }, args) ->
    is_verb txt || List.exists (fun (_, a) -> holds_step a) args
  | Pexp_constraint (inner, _) -> holds_step inner
  | _ -> false

(* The step calls of one test body, in the order they run, last first. The
   chain so far is an argument of each step (or of the pipe around it), so an
   argument that holds a step is the chain and the others are the step's values.
   Any other call is walked left to right, which keeps the written order.
   `chain->thenNoEvent` has no parentheses: the pipe's right side is the verb
   itself, a step with no values. [deep] also walks `let` bindings, arrays and
   constructor payloads, where a test may build part of its chain. *)
let rec ordered_steps ?(deep = false) (e : expression)
    (acc : (Longident.t * (arg_label * expression) list) list) :
    (Longident.t * (arg_label * expression) list) list =
  let walk acc e = ordered_steps ~deep e acc in
  match e.pexp_desc with
  | Pexp_apply ({ pexp_desc = Pexp_ident { txt; _ }; _ }, args) when is_verb txt ->
    let acc = List.fold_left (fun acc (_, a) -> if holds_step a then walk acc a else acc) acc args in
    (txt, List.filter (fun (_, a) -> not (holds_step a)) args) :: acc
  | Pexp_ident { txt; _ } when is_verb txt -> (txt, []) :: acc
  | Pexp_apply (_, args) -> List.fold_left (fun acc (_, a) -> walk acc a) acc args
  | Pexp_let (_, vbs, cont) ->
    let acc =
      if deep then List.fold_left (fun acc (vb : value_binding) -> walk acc vb.pvb_expr) acc vbs
      else acc
    in
    walk acc cont
  | Pexp_sequence (a, b) -> walk (walk acc a) b
  | Pexp_constraint (inner, _) -> walk acc inner
  | Pexp_construct (_, Some inner) when deep -> walk acc inner
  | Pexp_array els when deep -> List.fold_left walk acc els
  | _ -> acc

let last = function [] -> None | xs -> Some (List.nth xs (List.length xs - 1))

(* One asserted thing: `{kind, element, values}`, or `opaque` `of` the kind a
   step this walk cannot read stands in for, named by its source text. Dropped,
   `given: []` read as a history with nothing in it. *)
type entry = { kind : string; of_ : string option; element : string; values : Yojson.Safe.t list }

let entry ~kind ?(element = "") ?(values = []) () = { kind; of_ = None; element; values }

let opaque ?src ~(kind : string) (e : expression) : entry =
  { kind = "opaque"; of_ = Some kind;
    element = Option.value (source_text ?src e) ~default:""; values = [] }

let entry_fields (en : entry) : (string * Yojson.Safe.t) list =
  [ ("kind", `String en.kind) ]
  @ (match en.of_ with Some k -> [ ("of", `String k) ] | None -> [])
  @ [ ("element", `String en.element); ("values", `List en.values) ]

let step_json ~kind ~element ~values : Yojson.Safe.t =
  `Assoc (entry_fields (entry ~kind ~element ~values ()))

(* The thing a payload stands for: the second of an `(id, X)` pair, and the
   event inside `event(e)` / `Dcb.event(e, ~sourceId)`, which wraps a source's
   typed event for a sweep. *)
let rec payload_of (e : expression) : expression =
  match e.pexp_desc with
  | Pexp_tuple [ _; x ] -> payload_of x
  | Pexp_apply ({ pexp_desc = Pexp_ident { txt; _ }; _ }, args)
    when String.equal (step_name_of txt) "event" -> (
    match List.find_map (function (Nolabel, a) -> Some a | _ -> None) args with
    | Some a -> payload_of a
    | None -> e)
  | Pexp_constraint (inner, _) -> payload_of inner
  | _ -> e

(* A short value as text: an id, a message, a status. A string is its content,
   `#Completed` its name, `Some(x)` x, `None` nothing; anything else its source. *)
let rec text_value ?src (e : expression) : string =
  match e.pexp_desc with
  | Pexp_constant (Pconst_string (s, _, _)) -> s
  | Pexp_constant (Pconst_integer (s, _) | Pconst_float (s, _)) -> s
  | Pexp_construct ({ txt = Lident "None"; _ }, None) -> ""
  | Pexp_construct ({ txt = Lident "Some"; _ }, Some inner) -> text_value ?src inner
  | Pexp_construct ({ txt; _ }, None) -> flatten_longident txt
  | Pexp_variant (label, None) -> label
  | Pexp_ident { txt = (Lident _ | Ldot _) as lid; _ } -> flatten_longident lid
  | Pexp_constraint (inner, _) -> text_value ?src inner
  | _ -> Option.value (source_text ?src e) ~default:""

(* A record literal's entries: a record, a JS object literal (`{"sku": …}`,
   which reaches a PPX as `%obj`), or a constructor's record payload. *)
let rec entries_of ?src (e : expression) : Yojson.Safe.t list =
  match e.pexp_desc with
  | Pexp_record _ -> record_entries ?src e
  | Pexp_extension ({ txt = "obj"; _ }, PStr [ { pstr_desc = Pstr_eval (r, _); _ } ]) ->
    entries_of ?src r
  | Pexp_construct (_, Some inner) -> entries_of ?src inner
  | Pexp_constraint (inner, _) -> entries_of ?src inner
  | _ -> []

let is_record_like (e : expression) =
  match e.pexp_desc with
  | Pexp_record _ | Pexp_extension ({ txt = "obj"; _ }, _) -> true
  | _ -> false

(* A JSON payload written as a literal, `JSON.parseOrThrow(`{"sku": "x"}`)`:
   its object's entries, as example values. *)
let json_literal_entries (e : expression) : Yojson.Safe.t list =
  let rec value (j : Yojson.Safe.t) : Yojson.Safe.t =
    (* The last case is yojson 2's `Tuple and `Variant, which plain JSON never parses to.
       yojson 3 has neither, so there the case is unused (warning 11): one source builds
       against both. *)
    match[@warning "-11"] j with
    | `String s -> `Assoc [ ("kind", `String "string"); ("value", `String s) ]
    | `Int i -> `Assoc [ ("kind", `String "int"); ("value", `Int i) ]
    | `Intlit s -> `Assoc [ ("kind", `String "code"); ("value", `String s) ]
    | `Float f -> `Assoc [ ("kind", `String "float"); ("value", `Float f) ]
    | `Bool b -> `Assoc [ ("kind", `String "bool"); ("value", `Bool b) ]
    | `Null -> `Assoc [ ("kind", `String "null") ]
    | `List xs -> `Assoc [ ("kind", `String "list"); ("items", `List (List.map value xs)) ]
    | `Assoc kvs -> `Assoc [ ("kind", `String "record"); ("entries", `List (entries kvs)) ]
    | _ -> `Assoc [ ("kind", `String "null") ]
  and entries kvs = List.map (fun (k, v) -> `List [ `String k; value v ]) kvs in
  let literal =
    match e.pexp_desc with
    | Pexp_constant (Pconst_string (s, _, _)) -> Some s
    | Pexp_apply (_, [ (Nolabel, { pexp_desc = Pexp_constant (Pconst_string (s, _, _)); _ }) ]) ->
      Some s
    | _ -> None
  in
  match Option.map Yojson.Safe.from_string literal with
  | Some (`Assoc kvs) -> entries kvs
  | _ | (exception _) -> []

(* `Ctor({..})` → the constructor and its entries. *)
let ctor_entry ?src ~kind (e : expression) : entry =
  let p = payload_of e in
  match element_of_constructor ?src p with
  | Some (element, values) -> entry ~kind ~element ~values ()
  | None -> opaque ?src ~kind p

(* `(id, {..})` → the id and the record's entries; a bare record has no id. *)
let row_entry ?src ~kind (e : expression) : entry =
  match e.pexp_desc with
  | Pexp_tuple [ id; item ] -> entry ~kind ~element:(text_value ?src id) ~values:(entries_of ?src item) ()
  | _ when is_record_like e -> entry ~kind ~values:(entries_of ?src e) ()
  | Pexp_construct (_, Some _) -> ctor_entry ?src ~kind e
  | _ -> opaque ?src ~kind e

(* An array literal is N entries of one kind; `[]` is the [none] kind when the
   verb has one (`thenCommands([])` asserts that nothing was issued), else
   nothing. Anything else is one entry. *)
let each ?none (f : expression -> entry) (payload : expression) : entry list =
  match payload.pexp_desc, none with
  | Pexp_array [], Some k -> [ entry ~kind:k () ]
  | Pexp_array els, _ -> List.map f els
  | _ -> [ f payload ]

let state_entry ?src (e : expression) : entry =
  entry ~kind:"state" ~element:"state" ~values:(record_entries ?src e) ()

(* One step call as written. [grouped] is false for a step that has no place in
   the three groups: a second act (`andThenEvents`) or the capabilities a
   translation runs against. *)
type call = { group : string; verb : string; via : string option; grouped : bool; entries : entry list }

(* What one verb asserts. None for a verb this walk does not know. *)
let call_of ?src (lid : Longident.t) (args : (arg_label * expression) list) : call option =
  let verb = step_name_of lid in
  let pos = List.filter_map (function (Nolabel, e) -> Some e | _ -> None) args in
  let on_last f = match last pos with Some p -> f p | None -> [] in
  let labelled name =
    List.find_map
      (function ((Labelled l | Optional l), e) when String.equal l name -> Some e | _ -> None)
      args
  in
  let one kind ?element ?values () = [ entry ~kind ?element ?values () ] in
  let mk ?(grouped = true) group entries =
    Some { group; verb; via = step_via lid; grouped; entries }
  in
  let input p =
    match element_of_constructor ?src p with
    | Some (element, values) -> [ entry ~kind:"input" ~element ~values () ]
    | None ->
      let values = if is_record_like p then entries_of ?src p else json_literal_entries p in
      [ entry ~kind:"input" ~element:"externalInput" ~values () ]
  in
  match verb with
  (* given *)
  | "givenEvents" | "givenEvent" -> mk "given" (on_last (each (ctor_entry ?src ~kind:"event")))
  | "givenTodo" -> (
    match List.rev pos with
    | item :: id :: _ ->
      mk "given" (one "todo" ~element:(text_value ?src id) ~values:(entries_of ?src item) ())
    | _ -> mk "given" (on_last (fun p -> [ row_entry ?src ~kind:"todo" p ])))
  | "givenCapabilities" -> mk ~grouped:false "given" (one "capabilities" ())
  (* when *)
  | "whenCmd" | "whenCommand" -> mk "when" (on_last (each (ctor_entry ?src ~kind:"command")))
  | "whenInput" -> (
    match last pos with
    | Some p when is_record_like p -> mk "when" (input p)
    | Some p -> mk "when" [ ctor_entry ?src ~kind:"input" p ]
    | None -> mk "when" [])
  | "whenReceived" -> mk "when" (on_last input)
  | "whenEvent" | "whenEvents" -> mk "when" (on_last (each (ctor_entry ?src ~kind:"event")))
  (* The event a collect or resolve reacts to is the given one, moved here. *)
  | "whenCollect" | "whenResolve" -> mk "when" (one "event" ())
  | "whenSweep" | "whenReacts" | "whenPublishedThrough" | "whenExtensionReacts" ->
    mk "when" (one "sweep" ())
  | "whenProcess" | "whenTranslated" | "whenTranslateMocked" | "whenTranslateRetrying" ->
    mk "when" (one "process" ())
  | "whenExhausted" ->
    let element = match labelled "lastError" with Some e -> text_value ?src e | None -> "" in
    mk "when" (one "exhausted" ~element ())
  | "andThenEvents" -> mk ~grouped:false "when" (on_last (each (ctor_entry ?src ~kind:"event")))
  (* then *)
  | "thenEvent" | "thenEvents" -> mk "then" (on_last (each (ctor_entry ?src ~kind:"event")))
  | "thenError" -> mk "then" (on_last (each (ctor_entry ?src ~kind:"error")))
  | "thenSideEffect" -> mk "then" (on_last (each (ctor_entry ?src ~kind:"sideEffect")))
  (* `thenStateWithId(id, record)` names the row; the id routes the fold and is
     not part of the row's value. *)
  | "thenState" | "thenStates" | "thenStateWithId" | "thenStatesWithId" | "thenViewState"
  | "thenViewStates" ->
    mk "then" (on_last (each (state_entry ?src)))
  (* No element and no payload: the absence is the assertion. *)
  | "thenNoEvent" -> mk "then" (one "noEvent" ())
  | "thenNoState" -> mk "then" (one "noState" ())
  (* Not `error`: who may act is not something the lifecycle decides. *)
  | "thenRefused" -> mk "then" (one "forbidden" ())
  | "thenCommand" | "thenIssuesCommand" -> mk "then" (on_last (each (ctor_entry ?src ~kind:"command")))
  | "thenCommands" | "thenIssuesCommands" ->
    mk "then" (on_last (each ~none:"noCommand" (ctor_entry ?src ~kind:"command")))
  | "thenNoCommand" | "thenIssuesNoCommand" -> mk "then" (one "noCommand" ())
  | "thenTodos" | "thenScenarioTodos" ->
    mk "then" (on_last (each ~none:"noTodo" (row_entry ?src ~kind:"todo")))
  | "thenResolved" -> mk "then" (on_last (fun p -> one "resolved" ~element:(text_value ?src p) ()))
  | "thenTranslateError" | "thenNotUnderstood" ->
    mk "then" (on_last (fun p -> one "notUnderstood" ~element:(text_value ?src p) ()))
  | "thenRefusedInput" ->
    mk "then" (on_last (fun p -> one "inputRefused" ~element:(text_value ?src p) ()))
  | "thenSent" -> mk "then" (on_last (each ~none:"nothingSent" (ctor_entry ?src ~kind:"sent")))
  | "thenOutbound" -> mk "then" (on_last (each ~none:"nothingSent" (row_entry ?src ~kind:"sent")))
  | "thenNothingSent" | "thenOutboundNothing" -> mk "then" (one "nothingSent" ())
  | "thenTodoStatus" -> (
    match List.rev pos with
    | status :: id :: _ ->
      let values =
        Option.to_list
          (Option.map (fun v -> `List [ `String "id"; v ]) (example_of_expr ?src id))
      in
      mk "then" (one "todoStatus" ~element:(text_value ?src status) ~values ())
    | _ -> mk "then" (on_last (fun p -> one "todoStatus" ~element:(text_value ?src p) ())))
  | "thenRetryRecorded" -> mk "then" (on_last (fun p -> one "retries" ~element:(text_value ?src p) ()))
  | "thenPublicEvent" | "thenPublicEvents" ->
    mk "then" (on_last (each (ctor_entry ?src ~kind:"publicEvent")))
  | _ -> None

(* `givenEvent(e)->whenCollect`: the event the slice reacts to is the when, as
   for a view, so the given step is folded into the step that consumes it. *)
let absorb_reacted_events (calls : call list) : call list =
  List.rev
    (List.fold_left
       (fun acc (c : call) ->
         match acc with
         | (p : call) :: rest
           when (String.equal c.verb "whenCollect" || String.equal c.verb "whenResolve")
                && String.equal p.verb "givenEvent" ->
           { c with entries = p.entries } :: rest
         | _ -> c :: acc)
       [] calls)

let calls_of_body ?src (body : expression) : call list =
  ordered_steps ~deep:true body []
  |> List.rev
  |> List.filter_map (fun (lid, args) -> call_of ?src lid args)
  |> absorb_reacted_events

let steps_json (calls : call list) : Yojson.Safe.t list =
  List.concat_map
    (fun (c : call) ->
      List.map
        (fun en ->
          `Assoc
            ([ ("group", `String c.group); ("verb", `String c.verb) ]
             @ entry_fields en
             @ match c.via with Some v -> [ ("via", `String v) ] | None -> []))
        c.entries)
    calls

(* The three groups, read off the same calls: every given; the last when, since
   a group holds one act; and the thens written after it (all of them when
   there is no when). [steps] keeps every act, in order. *)
let extract_groups (calls : call list) :
    Yojson.Safe.t list * Yojson.Safe.t list * Yojson.Safe.t list =
  let indexed = List.mapi (fun i c -> (i, c)) (List.filter (fun (c : call) -> c.grouped) calls) in
  let last_when =
    List.fold_left (fun acc (i, (c : call)) -> if String.equal c.group "when" then Some i else acc)
      None indexed
  in
  let pick f =
    List.concat_map (fun (i, (c : call)) -> if f i c then List.map (fun en -> `Assoc (entry_fields en)) c.entries else [])
      indexed
  in
  let given = pick (fun _ c -> String.equal c.group "given") in
  let when_ = pick (fun i _ -> Some i = last_when) in
  let then_ =
    pick (fun i c ->
        String.equal c.group "then"
        && match last_when with Some w -> i > w | None -> true)
  in
  (given, when_, then_)

let extract_steps ?src (body : expression) :
    Yojson.Safe.t list * Yojson.Safe.t list * Yojson.Safe.t list =
  extract_groups (calls_of_body ?src body)

(* ── scenario-id comments (recovered from source text) ──────────────────── *)

(* The marker's two spellings. `// scenario-id:` is the current one; the codegen
   wrote `// spec-id:` before "spec" was reserved for a slice's definition file,
   and generated apps carry it until their next forward pass, so it is read for
   good. *)
let scenario_id_prefixes = [ "// scenario-id:"; "// spec-id:" ]

let scenario_ids_of_source (text : string) : (int * string) list =
  let id_of_line (trimmed : string) : string option =
    List.find_map
      (fun prefix ->
        let lp = String.length prefix and lt = String.length trimmed in
        if lt >= lp && String.equal (String.sub trimmed 0 lp) prefix then
          Some (String.trim (String.sub trimmed lp (lt - lp)))
        else None)
      scenario_id_prefixes
  in
  List.concat
    (List.mapi
       (fun i line ->
         match id_of_line (String.trim line) with
         | Some id -> [ (i + 1, id) ]
         | None -> [])
       (String.split_on_char '\n' text))

let read_scenario_ids (fname : string) : (int * string) list =
  match read_source fname with
  | Some text -> scenario_ids_of_source text
  | None -> []

(* The id of the test starting on [line]: the nearest marker above it, and only
   when no other test starts between that marker and [line]. A marker belongs to
   the one test directly below it. Taking the nearest marker however far above
   gave a hand-written test added below a form-written one the form-written
   test's id, so two scenarios reached the reverse pass under one id. The VS Code
   extension reads a marker the same way, so both readers agree on a file.
   [tests] holds the start line of every test in the file. *)
let scenario_id_for (line : int) ~(tests : int list) (ids : (int * string) list) :
    string option =
  let nearest =
    List.fold_left
      (fun best (n, id) ->
        if n < line then
          match best with
          | Some (bn, _) when bn >= n -> best
          | _ -> Some (n, id)
        else best)
      None ids
  in
  match nearest with
  | Some (n, id) when not (List.exists (fun t -> n < t && t < line) tests) -> Some id
  | _ -> None

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
  (* `testSync` is a test too; `~timeout` and other labels are not its title
     or body. *)
  | Pexp_apply ({ pexp_desc = Pexp_ident { txt; _ }; _ }, args)
    when List.mem (step_name_of txt) [ "test"; "testSync" ] -> (
    let arg_exprs = List.filter_map (function (Nolabel, a) -> Some a | _ -> None) args in
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
            Pexp_apply ({ pexp_desc = Pexp_ident { txt; _ }; _ }, args);
          _ },
        _ )
    when String.equal (step_name_of txt) "describe" -> (
    match List.map snd args with
    | name_e :: fn :: _ -> (
      match (string_of_expr name_e, fun_body fn) with
      | Some spec_name, Some body ->
        Some (spec_name, List.rev (collect_tests body []))
      | _ -> None)
    | _ -> None)
  | _ -> None

let gwt_fragment_json ~fname (str : structure) : Yojson.Safe.t option =
  let src = read_source fname in
  let scenario_ids =
    match src with Some text -> scenario_ids_of_source text | None -> []
  in
  let describes = List.filter_map describe_of_item str in
  match describes with
  | [] -> None
  | _ ->
    let spec_name =
      match describes with (n, _) :: _ -> n | [] -> filename_stem fname
    in
    let test_lines =
      List.concat_map
        (fun (_, tests) ->
          List.map (fun ((loc : Location.t), _, _) -> loc.loc_start.pos_lnum) tests)
        describes
    in
    let scenarios =
      List.concat_map
        (fun (_, tests) ->
          List.map
            (fun ((loc : Location.t), title, body) ->
              let scenario_id =
                match
                  scenario_id_for loc.loc_start.pos_lnum ~tests:test_lines scenario_ids
                with
                | Some id -> id
                | None -> ""
              in
              let calls = calls_of_body ?src body in
              let given, when_, then_ = extract_groups calls in
              (* `specId` repeats the id for the released codegen, which reads
                 only that key; it goes once the codegen reads `scenarioId`. *)
              `Assoc
                [ ("scenarioId", `String scenario_id);
                  ("specId", `String scenario_id);
                  ("title", `String title);
                  ("given", `List given);
                  ("when", `List when_);
                  ("then", `List then_);
                  ("steps", `List (steps_json calls)) ])
            tests)
        describes
    in
    Some
      (`Assoc
         [ ("specName", `String spec_name);
           ("stem", `String (filename_stem fname));
           ("file", `String (repo_relative fname));
           ( "componentKind",
             match Util.derive_gwt_kind fname with Some k -> `String k | None -> `Null );
           ("scenarios", `List scenarios) ])

let gwt_sidecar_path (fname : string) : string =
  if Filename.check_suffix fname ".res" then
    Filename.chop_suffix fname ".res" ^ ".gwt.json"
  else fname ^ ".gwt.json"

(* A GWT file the attribute cannot reach: a multi-source read model wires one
   `Make` module per source mapping, so it has no single Spec to include and
   carries no `@@reventless.gwt`. Its scenarios are still scenarios, and the one
   in the shipped hybrid shop is the corpus for a view two other components are
   labelled against — so the emit keys off the filename as well, matching the
   `_GWT` / `GwtTest` stems the rest of the pipeline already recognises.

   Nothing is forced: a file with no top-level `describe` yields no fragment. *)
let looks_like_gwt_file (fname : string) : bool =
  let stem = filename_stem fname in
  ends_with stem "_GWT" || ends_with stem "GwtTest" || ends_with stem "Gwt"

(* Public entry — called from the dispatcher for GWT files with the original
   test structure (before the GWT include/open injection). *)
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

(* ════════════════════════════════════════════════════════════════════════
   Example files — emit <Stem>.examples.json for a file carrying
   `@@reventless.examples`: a module of named example values a scenario refers
   to by name (`lines: [OrderingExamples.dockLine]`). The GWT sidecar records
   such a value as a `ref`; this sidecar is where a reader resolves it, without
   parsing ReScript.

     @@reventless.examples
     let dockLine: orderLine = {productId: pid("p1"), quantity: 1, …}
     let o1 = OrderId.make("o1")

   Only top-level `let`s binding a single name count, annotated or not; any
   other item is ignored. The attribute selects no mode and the file is
   otherwise compiled as written — the dispatcher only removes the attribute.
   ════════════════════════════════════════════════════════════════════════ *)

let examples_attr_name = "reventless.examples"

let is_examples_attr (a : attribute) : bool = String.equal a.attr_name.txt examples_attr_name

let find_examples_attr (str : structure) : attribute option =
  List.find_map
    (fun (item : structure_item) ->
      match item.pstr_desc with
      | Pstr_attribute a when is_examples_attr a -> Some a
      | _ -> None)
    str

let strip_examples_attr (str : structure) : structure =
  List.filter
    (fun (item : structure_item) ->
      match item.pstr_desc with Pstr_attribute a -> not (is_examples_attr a) | _ -> true)
    str

(* A type as ReScript writes it, for when its source text is not to hand. *)
let rec type_to_string (ct : core_type) : string =
  match ct.ptyp_desc with
  | Ptyp_constr ({ txt; _ }, []) -> flatten_longident txt
  | Ptyp_constr ({ txt; _ }, args) ->
    flatten_longident txt ^ "<" ^ String.concat ", " (List.map type_to_string args) ^ ">"
  | Ptyp_var v -> "'" ^ v
  | Ptyp_poly (_, t) -> type_to_string t
  | _ -> ""

(* The annotation as written: its source text when the file is at hand, else the
   printed form above. *)
let type_text ?src (ct : core_type) : string =
  match text_at ?src ct.ptyp_loc with Some t -> t | None -> type_to_string ct

let unknown_kind : Yojson.Safe.t =
  `Assoc [ ("kind", `String "custom"); ("name", `String "Unknown") ]

let examples_fragment_json ~fname (str : structure) : Yojson.Safe.t =
  let src = read_source fname in
  let examples =
    List.concat_map
      (fun (item : structure_item) ->
        match item.pstr_desc with
        | Pstr_value (_, vbs) ->
          List.filter_map
            (fun (vb : value_binding) ->
              match named_binding vb with
              | None -> None
              | Some (name, ct, e) ->
                let type_s, kind =
                  match ct with
                  | Some ct -> (type_text ?src ct, kind_of_type ct)
                  | None -> ("", unknown_kind)
                in
                (* No value only when the source is not to hand for a value
                   the walk records as code; the entry is dropped then, as a
                   GWT field is. *)
                Option.map
                  (fun value ->
                    `Assoc
                      [ ("name", `String name);
                        ("type", `String type_s);
                        ("kind", kind);
                        ("line", `Int vb.pvb_loc.loc_start.pos_lnum);
                        ("value", value) ])
                  (example_of_expr ?src e))
            vbs
        | _ -> [])
      str
  in
  `Assoc
    [ ("module", `String (filename_stem fname));
      ("file", `String (repo_relative fname));
      ("examples", `List examples) ]

let examples_sidecar_path (fname : string) : string =
  if Filename.check_suffix fname ".res" then
    Filename.chop_suffix fname ".res" ^ ".examples.json"
  else fname ^ ".examples.json"

(* Public entry — called from the dispatcher, before any other pass, for a file
   carrying `@@reventless.examples`. *)
let maybe_emit_examples ~fname (str : structure) : unit =
  if is_enabled () && fname <> "" then
    try
      let json = examples_fragment_json ~fname str in
      let oc = open_out (examples_sidecar_path fname) in
      output_string oc (Yojson.Safe.pretty_to_string json);
      output_char oc '\n';
      close_out oc
    with exn ->
      Printf.eprintf "[reventless-ppx] examples sidecar emit failed for %s: %s\n"
        fname (Printexc.to_string exn)

(* ════════════════════════════════════════════════════════════════════════
   Shared types — emit <Stem>.types.json for a plain module declaring `@schema`
   types that components share (`DeliveryOption.t`). A spec's field of that type
   reads `custom DeliveryOption.t`; this sidecar is where a reader resolves it,
   as the entry `typeName: "t"` of the sidecar whose `module` is `DeliveryOption`.

   The dispatcher decides which modules qualify (no mode attribute, not a GWT or
   examples file); a module with no top-level `@schema` type yields no fragment.
   Not `.model.json`: every reader of those takes the file for a component.
   ════════════════════════════════════════════════════════════════════════ *)

let types_fragment_json ?src ~fname (str : structure) : Yojson.Safe.t option =
  let schema_types =
    List.concat_map
      (fun (item : structure_item) ->
        match item.pstr_desc with
        | Pstr_type (_, tds) -> List.filter is_schema_type tds
        | _ -> [])
      str
  in
  match schema_types with
  | [] -> None
  | _ ->
    Some
      (`Assoc
         [ ("module", `String (filename_stem fname));
           ("file", `String (repo_relative fname));
           ("types", `List (List.filter_map (fun td -> type_entry ?src td) schema_types)) ])

let types_sidecar_path (fname : string) : string =
  if Filename.check_suffix fname ".res" then
    Filename.chop_suffix fname ".res" ^ ".types.json"
  else fname ^ ".types.json"

(* Public entry — called from the dispatcher, with the file as authored, for a
   module no other sidecar covers. *)
let maybe_emit_types ~fname (str : structure) : unit =
  if is_enabled () && fname <> "" then
    try
      match types_fragment_json ?src:(read_source fname) ~fname str with
      | Some json ->
        let oc = open_out (types_sidecar_path fname) in
        output_string oc (Yojson.Safe.pretty_to_string json);
        output_char oc '\n';
        close_out oc
      | None -> ()
    with exn ->
      Printf.eprintf "[reventless-ppx] types sidecar emit failed for %s: %s\n"
        fname (Printexc.to_string exn)
