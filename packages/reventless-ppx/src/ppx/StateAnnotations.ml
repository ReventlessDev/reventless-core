open Ppxlib

(* ── @id / @compositeId attribute helpers ── *)

let has_id_field_attr (attrs : attributes) =
  List.exists (fun (attr : attribute) ->
    String.equal attr.attr_name.txt "id"
  ) attrs

let strip_id_field_attr (attrs : attributes) =
  List.filter (fun (attr : attribute) ->
    not (String.equal attr.attr_name.txt "id")
  ) attrs

let has_composite_id_field_attr (attrs : attributes) =
  List.exists (fun (attr : attribute) ->
    String.equal attr.attr_name.txt "compositeId"
  ) attrs

let get_composite_id_sep (attrs : attributes) =
  let opt = List.find_opt (fun (attr : attribute) ->
    String.equal attr.attr_name.txt "compositeId"
  ) attrs in
  match opt with
  | None -> "/"
  | Some attr ->
    (match attr.attr_payload with
     | PStr [{ pstr_desc = Pstr_eval ({pexp_desc = Pexp_constant (Pconst_string (s, _, _)); _}, _); _ }] -> s
     | _ -> "/")

let strip_composite_id_field_attr (attrs : attributes) =
  List.filter (fun (attr : attribute) ->
    not (String.equal attr.attr_name.txt "compositeId")
  ) attrs

(* ── @subId / @compositeSubId attribute helpers ── *)

let has_subid_field_attr (attrs : attributes) =
  List.exists (fun (attr : attribute) ->
    String.equal attr.attr_name.txt "subId"
  ) attrs

let strip_subid_field_attr (attrs : attributes) =
  List.filter (fun (attr : attribute) ->
    not (String.equal attr.attr_name.txt "subId")
  ) attrs

let has_composite_subid_field_attr (attrs : attributes) =
  List.exists (fun (attr : attribute) ->
    String.equal attr.attr_name.txt "compositeSubId"
  ) attrs

let get_composite_subid_sep (attrs : attributes) =
  let opt = List.find_opt (fun (attr : attribute) ->
    String.equal attr.attr_name.txt "compositeSubId"
  ) attrs in
  match opt with
  | None -> "/"
  | Some attr ->
    (match attr.attr_payload with
     | PStr [{ pstr_desc = Pstr_eval ({pexp_desc = Pexp_constant (Pconst_string (s, _, _)); _}, _); _ }] -> s
     | _ -> "/")

let strip_composite_subid_field_attr (attrs : attributes) =
  List.filter (fun (attr : attribute) ->
    not (String.equal attr.attr_name.txt "compositeSubId")
  ) attrs

(* ── @status attribute helpers ──
   Marks the lifecycle status field on a state record. AutoUI's command-menu
   filter reads the marked field per row and matches it against each command's
   `allowedStates` set. At most one `@status` per record; duplicates are
   reported in [make_state_annotations_binding]. *)

let has_status_field_attr (attrs : attributes) =
  List.exists (fun (attr : attribute) ->
    String.equal attr.attr_name.txt "status"
  ) attrs

let strip_status_field_attr (attrs : attributes) =
  List.filter (fun (attr : attribute) ->
    not (String.equal attr.attr_name.txt "status")
  ) attrs

(* ── @groupBy attribute helpers ──
   Marks the field a list view should section its rows by. AutoUI's list view
   reads the marked field per row and groups rows sharing the same value.
   At most one @groupBy per record; duplicates are reported in
   [make_state_annotations_binding]. *)

let has_group_by_field_attr (attrs : attributes) =
  List.exists (fun (attr : attribute) ->
    String.equal attr.attr_name.txt "groupBy"
  ) attrs

let strip_group_by_field_attr (attrs : attributes) =
  List.filter (fun (attr : attribute) ->
    not (String.equal attr.attr_name.txt "groupBy")
  ) attrs

let is_string_type (ct : core_type) =
  match ct.ptyp_desc with
  | Ptyp_constr ({ txt = Lident "string"; _ }, []) -> true
  | _ -> false

(** Find the @schema type state declaration in the structure, if it's a record type.
    Returns the list of label_declarations. *)
let find_schema_state_record (str : structure) : label_declaration list option =
  let rec scan = function
    | [] -> None
    | item :: rest ->
      (match item.pstr_desc with
       | Pstr_type (_, decls) ->
         let found = List.find_opt (fun (td : type_declaration) ->
           String.equal td.ptype_name.txt "state"
           && Util.has_attr "schema" td.ptype_attributes
         ) decls in
         (match found with
          | Some td ->
            (match td.ptype_kind with
             | Ptype_record fields -> Some fields
             | _ -> None)
          | None -> scan rest)
       | _ -> scan rest)
  in
  scan str

(** Strip @subId and @compositeSubId attributes from @schema type state record fields. *)
let strip_sub_id_attrs (str : structure) : structure =
  List.map (fun (item : structure_item) ->
    match item.pstr_desc with
    | Pstr_type (rf, decls) ->
      let new_decls = List.map (fun (td : type_declaration) ->
        if not (String.equal td.ptype_name.txt "state"
                && Util.has_attr "schema" td.ptype_attributes) then td
        else
          match td.ptype_kind with
          | Ptype_record fields ->
            let new_fields = List.map (fun (ld : label_declaration) ->
              let attrs = ld.pld_attributes
                          |> strip_subid_field_attr
                          |> strip_composite_subid_field_attr in
              { ld with pld_attributes = attrs }
            ) fields in
            { td with ptype_kind = Ptype_record new_fields }
          | _ -> td
      ) decls in
      { item with pstr_desc = Pstr_type (rf, new_decls) }
    | _ -> item
  ) str

(** Returns true if the @schema type state record has any @subId or @compositeSubId annotations. *)
let has_sub_id_annotations (str : structure) : bool =
  match find_schema_state_record str with
  | None -> false
  | Some fields ->
    List.exists (fun (ld : label_declaration) ->
      has_subid_field_attr ld.pld_attributes
      || has_composite_subid_field_attr ld.pld_attributes
    ) fields

(** Build a %raw("...") expression. *)
let raw_expr ~loc js_code =
  let payload =
    PStr [{ pstr_desc =
              Pstr_eval (
                Ast_builder.Default.estring ~loc js_code,
                []);
            pstr_loc = loc }]
  in
  { pexp_desc = Pexp_extension ({ txt = "raw"; loc }, payload);
    pexp_loc = loc;
    pexp_loc_stack = [];
    pexp_attributes = [] }

(** Build a `(record : Reventless.ReadModel.subIdConfig<state>)` type constraint expression. *)
let constrain_sub_id_record ~loc (record : expression) =
  let state_type = { ptyp_desc = Ptyp_constr ({ txt = Lident "state"; loc }, []);
                     ptyp_loc = loc; ptyp_loc_stack = []; ptyp_attributes = [] } in
  let ty = { ptyp_desc = Ptyp_constr (
               { txt = Ldot (Ldot (Lident "Reventless", "ReadModel"), "subIdConfig"); loc },
               [state_type]);
             ptyp_loc = loc; ptyp_loc_stack = []; ptyp_attributes = [] } in
  { pexp_desc = Pexp_constraint (record, ty);
    pexp_loc = loc; pexp_loc_stack = []; pexp_attributes = [] }

(** Generate `let subIdConfig = Some({ subIdField: "name", getSubId: %raw("state => state.name") })` *)
let gen_single_sub_id ~loc (field_name : string) =
  let field_str = Ast_builder.Default.estring ~loc field_name in
  let js_fn = Printf.sprintf "state => state.%s" field_name in
  let get_sub_id = raw_expr ~loc js_fn in
  let record = { pexp_desc = Pexp_record ([
    ({ txt = Lident "subIdField"; loc }, field_str);
    ({ txt = Lident "getSubId"; loc }, get_sub_id);
  ], None);
    pexp_loc = loc; pexp_loc_stack = []; pexp_attributes = [] } in
  let constrained = constrain_sub_id_record ~loc record in
  let some_expr = { pexp_desc = Pexp_construct (
    { txt = Lident "Some"; loc },
    Some constrained);
    pexp_loc = loc; pexp_loc_stack = []; pexp_attributes = [] } in
  [%stri let subIdConfig = [%e some_expr]]

(** Generate `let subIdConfig = Some({ subIdField: "_subId",
      getSubId: %raw("state => state.f1 + sep + state.f2 + ...") })` *)
let gen_composite_sub_id ~loc (fields : (string * string) list) =
  (* Build JS: state => state.f1 + sep0 + state.f2 + ...
     The separator from field[i] goes BETWEEN field[i] and field[i+1]. *)
  let fields_arr = Array.of_list fields in
  let n = Array.length fields_arr in
  let js_parts = List.init n (fun i ->
    let (field_name, _) = fields_arr.(i) in
    if i = 0 then Printf.sprintf "state.%s" field_name
    else
      let (_, prev_sep) = fields_arr.(i - 1) in
      Printf.sprintf " + \"%s\" + state.%s" prev_sep field_name
  ) in
  let js_fn = "state => " ^ String.concat "" js_parts in
  let get_sub_id = raw_expr ~loc js_fn in
  let sub_id_field_str = Ast_builder.Default.estring ~loc "_subId" in
  let record = { pexp_desc = Pexp_record ([
    ({ txt = Lident "subIdField"; loc }, sub_id_field_str);
    ({ txt = Lident "getSubId"; loc }, get_sub_id);
  ], None);
    pexp_loc = loc; pexp_loc_stack = []; pexp_attributes = [] } in
  let constrained = constrain_sub_id_record ~loc record in
  let some_expr = { pexp_desc = Pexp_construct (
    { txt = Lident "Some"; loc },
    Some constrained);
    pexp_loc = loc; pexp_loc_stack = []; pexp_attributes = [] } in
  [%stri let subIdConfig = [%e some_expr]]

(** Analyse @schema type state record fields and generate the appropriate subIdConfig binding.
    Returns `[let subIdConfig = ...]` (list with one item) or `[]` if no @schema type state record.
    Also strips @subId/@compositeSubId attributes from the structure (modifies in place via returned structure). *)
let generate_sub_id_config ~loc (str : structure) : structure_item list =
  match find_schema_state_record str with
  | None -> [[%stri let subIdConfig = None]]
  | Some fields ->
    let sub_id_fields = List.filter (fun (ld : label_declaration) ->
      has_subid_field_attr ld.pld_attributes
    ) fields in
    let composite_fields = List.filter (fun (ld : label_declaration) ->
      has_composite_subid_field_attr ld.pld_attributes
    ) fields in
    let has_sub_id = sub_id_fields <> [] in
    let has_composite = composite_fields <> [] in
    (* Validate: can't have both *)
    if has_sub_id && has_composite then
      Location.raise_errorf ~loc
        "@subId and @compositeSubId cannot both appear on the same type";
    (* Validate: @subId on at most one field *)
    if List.length sub_id_fields > 1 then
      Location.raise_errorf ~loc
        "@subId can only appear on one field";
    (* @subId case *)
    if has_sub_id then begin
      let ld = List.hd sub_id_fields in
      if not (is_string_type ld.pld_type) then
        Location.raise_errorf ~loc
          "@subId can only be used on string fields, but '%s' is not a string"
          ld.pld_name.txt;
      [gen_single_sub_id ~loc ld.pld_name.txt]
    end
    (* @compositeSubId case *)
    else if has_composite then begin
      (* Validate all composite fields are strings *)
      List.iter (fun (ld : label_declaration) ->
        if not (is_string_type ld.pld_type) then
          Location.raise_errorf ~loc
            "@compositeSubId can only be used on string fields, but '%s' is not a string"
            ld.pld_name.txt
      ) composite_fields;
      (* Collect field names with separators in declaration order *)
      let field_info = List.map (fun (ld : label_declaration) ->
        let sep = get_composite_subid_sep ld.pld_attributes in
        (ld.pld_name.txt, sep)
      ) composite_fields in
      [gen_composite_sub_id ~loc field_info]
    end
    else
      [[%stri let subIdConfig = None]]

(* ── @status: structure-level strip ── *)

(** Strip @status attributes from @schema type state record fields. Mirrors
    [strip_id_attrs] / [strip_subid_attrs]. *)
let strip_status_attrs (str : structure) : structure =
  List.map (fun (item : structure_item) ->
    match item.pstr_desc with
    | Pstr_type (rf, decls) ->
      let new_decls = List.map (fun (td : type_declaration) ->
        if not (String.equal td.ptype_name.txt "state"
                && Util.has_attr "schema" td.ptype_attributes) then td
        else
          match td.ptype_kind with
          | Ptype_record fields ->
            let new_fields = List.map (fun (ld : label_declaration) ->
              { ld with pld_attributes = strip_status_field_attr ld.pld_attributes }
            ) fields in
            { td with ptype_kind = Ptype_record new_fields }
          | _ -> td
      ) decls in
      { item with pstr_desc = Pstr_type (rf, new_decls) }
    | _ -> item
  ) str

(* ── @groupBy: structure-level strip ── *)

(** Strip @groupBy attributes from @schema type state record fields. Mirrors
    [strip_status_attrs]. *)
let strip_group_by_attrs (str : structure) : structure =
  List.map (fun (item : structure_item) ->
    match item.pstr_desc with
    | Pstr_type (rf, decls) ->
      let new_decls = List.map (fun (td : type_declaration) ->
        if not (String.equal td.ptype_name.txt "state"
                && Util.has_attr "schema" td.ptype_attributes) then td
        else
          match td.ptype_kind with
          | Ptype_record fields ->
            let new_fields = List.map (fun (ld : label_declaration) ->
              { ld with pld_attributes = strip_group_by_field_attr ld.pld_attributes }
            ) fields in
            { td with ptype_kind = Ptype_record new_fields }
          | _ -> td
      ) decls in
      { item with pstr_desc = Pstr_type (rf, new_decls) }
    | _ -> item
  ) str

(* ── @id / @compositeId: makeId generation ── *)

(** Strip @id and @compositeId attributes from @schema type state record fields. *)
let strip_id_attrs (str : structure) : structure =
  List.map (fun (item : structure_item) ->
    match item.pstr_desc with
    | Pstr_type (rf, decls) ->
      let new_decls = List.map (fun (td : type_declaration) ->
        if not (String.equal td.ptype_name.txt "state"
                && Util.has_attr "schema" td.ptype_attributes) then td
        else
          match td.ptype_kind with
          | Ptype_record fields ->
            let new_fields = List.map (fun (ld : label_declaration) ->
              let attrs = ld.pld_attributes
                          |> strip_id_field_attr
                          |> strip_composite_id_field_attr in
              { ld with pld_attributes = attrs }
            ) fields in
            { td with ptype_kind = Ptype_record new_fields }
          | _ -> td
      ) decls in
      { item with pstr_desc = Pstr_type (rf, new_decls) }
    | _ -> item
  ) str

(** Returns true if the @schema type state record has any @id or @compositeId annotations. *)
let has_id_annotations (str : structure) : bool =
  match find_schema_state_record str with
  | None -> false
  | Some fields ->
    List.exists (fun (ld : label_declaration) ->
      has_id_field_attr ld.pld_attributes
      || has_composite_id_field_attr ld.pld_attributes
    ) fields

(** Generate `let makeId = %raw("state => state.fieldName")` *)
let gen_single_id ~loc (field_name : string) =
  let js_fn = Printf.sprintf "state => state.%s" field_name in
  let make_id = raw_expr ~loc js_fn in
  [%stri let makeId = [%e make_id]]

(** Generate `let makeId = %raw("state => state.f1 + sep + state.f2 + ...")` *)
let gen_composite_id ~loc (fields : (string * string) list) =
  let fields_arr = Array.of_list fields in
  let n = Array.length fields_arr in
  let js_parts = List.init n (fun i ->
    let (field_name, _) = fields_arr.(i) in
    if i = 0 then Printf.sprintf "state.%s" field_name
    else
      let (_, prev_sep) = fields_arr.(i - 1) in
      Printf.sprintf " + \"%s\" + state.%s" prev_sep field_name
  ) in
  let js_fn = "state => " ^ String.concat "" js_parts in
  let make_id = raw_expr ~loc js_fn in
  [%stri let makeId = [%e make_id]]

(** Analyse @schema type state record fields and generate the makeId binding if
    @id or @compositeId annotations are present. Returns [] when no annotations found. *)
let generate_make_id ~loc (str : structure) : structure_item list =
  match find_schema_state_record str with
  | None -> []
  | Some fields ->
    let id_fields = List.filter (fun (ld : label_declaration) ->
      has_id_field_attr ld.pld_attributes
    ) fields in
    let composite_fields = List.filter (fun (ld : label_declaration) ->
      has_composite_id_field_attr ld.pld_attributes
    ) fields in
    let has_id = id_fields <> [] in
    let has_composite = composite_fields <> [] in
    if not has_id && not has_composite then []
    else begin
      (* Validate: can't have both *)
      if has_id && has_composite then
        Location.raise_errorf ~loc
          "@id and @compositeId cannot both appear on the same type";
      (* Validate: @id on at most one field *)
      if List.length id_fields > 1 then
        Location.raise_errorf ~loc
          "@id can only appear on one field";
      (* @id case *)
      if has_id then begin
        let ld = List.hd id_fields in
        if not (is_string_type ld.pld_type) then
          Location.raise_errorf ~loc
            "@id can only be used on string fields, but '%s' is not a string"
            ld.pld_name.txt;
        [gen_single_id ~loc ld.pld_name.txt]
      end
      (* @compositeId case *)
      else begin
        (* Validate all composite fields are strings *)
        List.iter (fun (ld : label_declaration) ->
          if not (is_string_type ld.pld_type) then
            Location.raise_errorf ~loc
              "@compositeId can only be used on string fields, but '%s' is not a string"
              ld.pld_name.txt
        ) composite_fields;
        let field_info = List.map (fun (ld : label_declaration) ->
          let sep = get_composite_id_sep ld.pld_attributes in
          (ld.pld_name.txt, sep)
        ) composite_fields in
        [gen_composite_id ~loc field_info]
      end
    end

(* ── @index / @indexSubId: config generation ── *)

(** Infer the DynamoDB attribute type string from a ReScript core type.
    `int` and `float` → "N"; everything else (including `string`) → "S". *)
let infer_dynamo_type (ct : core_type) =
  match ct.ptyp_desc with
  | Ptyp_constr ({ txt = Lident "int"; _ }, []) -> "N"
  | Ptyp_constr ({ txt = Lident "float"; _ }, []) -> "N"
  | _ -> "S"

(** Find a string value for a named key in a record expression field list. *)
let find_record_str key fields =
  match List.find_opt (fun (lid, _) ->
    match lid.txt with Lident k -> String.equal k key | _ -> false
  ) fields with
  | Some (_, { pexp_desc = Pexp_constant (Pconst_string (s, _, _)); _ }) -> Some s
  | _ -> None

(** Get the index name from an `@index` or `@indexSubId` attribute.
    Accepts either a plain string `@index("name")` or a record `@index({name: "name", ...})`.
    Returns `""` for unnamed `@index` (no payload or empty payload). *)
let get_index_name (attr : attribute) =
  match attr.attr_payload with
  | PStr [{ pstr_desc = Pstr_eval ({pexp_desc = Pexp_constant (Pconst_string (s, _, _)); _}, _); _ }] -> s
  | PStr [{ pstr_desc = Pstr_eval ({pexp_desc = Pexp_record (fields, _); _}, _); _ }] ->
    (match find_record_str "name" fields with Some s -> s | None -> "")
  | _ -> ""

(** Extract optional index parameters from a record-form `@index({...})` attribute.
    Returns `(projection_str, include_fields, group, auth_table)` where
    `projection_str` is one of `"ALL"`, `"KEYS_ONLY"`, `"INCLUDE"` (default `"ALL"`). *)
let get_index_options (attr : attribute) =
  match attr.attr_payload with
  | PStr [{ pstr_desc = Pstr_eval ({pexp_desc = Pexp_record (fields, _); _}, _); _ }] ->
    let find_str key = find_record_str key fields in
    let find_str_array key =
      match List.find_opt (fun (lid, _) ->
        match lid.txt with Lident k -> String.equal k key | _ -> false
      ) fields with
      | Some (_, { pexp_desc = Pexp_array elems; _ }) ->
        Some (List.filter_map (fun e -> match e.pexp_desc with
          | Pexp_constant (Pconst_string (s, _, _)) -> Some s
          | _ -> None) elems)
      | _ -> None
    in
    let projection = (match find_str "projection" with Some s -> s | None -> "ALL") in
    let include_fields = (match find_str_array "fields" with Some xs -> xs | None -> []) in
    let group = find_str "group" in
    let auth_table = find_str "authTable" in
    (projection, include_fields, group, auth_table)
  | _ -> ("ALL", [], None, None)

let has_index_field_attr (attrs : attributes) =
  List.exists (fun (attr : attribute) -> String.equal attr.attr_name.txt "index") attrs

let has_index_sk_field_attr (attrs : attributes) =
  List.exists (fun (attr : attribute) -> String.equal attr.attr_name.txt "indexSubId") attrs

let strip_index_field_attrs (attrs : attributes) =
  List.filter (fun (attr : attribute) ->
    not (String.equal attr.attr_name.txt "index"
         || String.equal attr.attr_name.txt "indexSubId")
  ) attrs

(** Get the `@index` attribute from a field's attr list (may be absent). *)
let find_index_attr (attrs : attributes) =
  List.find_opt (fun (a : attribute) -> String.equal a.attr_name.txt "index") attrs

let find_index_sk_attr (attrs : attributes) =
  List.find_opt (fun (a : attribute) -> String.equal a.attr_name.txt "indexSubId") attrs

(** Generate a `projectionType` constructor expression. *)
let gen_projection_expr ~loc ~projection ~include_fields =
  let rm_ctor_name = match projection with
    | "KEYS_ONLY" -> "KEYS_ONLY"
    | "INCLUDE" -> "INCLUDE"
    | _ -> "ALL"
  in
  let payload = match rm_ctor_name with
    | "INCLUDE" ->
      let strs = List.map (Ast_builder.Default.estring ~loc) include_fields in
      let arr = { pexp_desc = Pexp_array strs; pexp_loc = loc; pexp_loc_stack = []; pexp_attributes = [] } in
      Some arr
    | _ -> None
  in
  { pexp_desc = Pexp_construct (
      { txt = Ldot (Ldot (Lident "Reventless", "ReadModel"), rm_ctor_name); loc }, payload);
    pexp_loc = loc; pexp_loc_stack = []; pexp_attributes = [] }

(** Generate an `authorization` record expression from group + tableName strings. *)
let gen_authorization_expr ~loc ~group ~auth_table =
  let estr = Ast_builder.Default.estring ~loc in
  { pexp_desc = Pexp_record ([
      ({ txt = Lident "tableName"; loc }, estr auth_table);
      ({ txt = Lident "group"; loc }, estr group);
    ], None);
    pexp_loc = loc; pexp_loc_stack = []; pexp_attributes = [] }

(** Generate a `pkFields`/`skFields` array expression from a list of field names. *)
let gen_str_array ~loc strs =
  { pexp_desc = Pexp_array (List.map (Ast_builder.Default.estring ~loc) strs);
    pexp_loc = loc; pexp_loc_stack = []; pexp_attributes = [] }

(** Build a single indexConfig record expression.
    `pk_source_fields` / `sk_source_fields` are the original field names for composite keys;
    when present, also emit `pkFields`/`skFields` so QueryDb_Operations can inject them. *)
let gen_index_config_expr ~loc ~index ~type_ ~id_field ~sub_id_field
    ~pk_source_fields ~sk_source_fields ~sep
    ~projection ~include_fields ~auth =
  let estr s = Ast_builder.Default.estring ~loc s in
  let required = [
    ({ txt = Lident "index"; loc }, estr index);
    ({ txt = Lident "type_"; loc }, estr type_);
    ({ txt = Lident "projectionType"; loc }, gen_projection_expr ~loc ~projection ~include_fields);
  ] in
  let opt_id = match id_field with
    | Some n -> [({ txt = Lident "idField"; loc }, estr n)]
    | None -> []
  in
  let opt_sk = match sub_id_field with
    | Some n -> [({ txt = Lident "subIdField"; loc }, estr n)]
    | None -> []
  in
  let opt_pk_fields = match pk_source_fields with
    | [] | [_] -> []
    | fs -> [({ txt = Lident "pkFields"; loc }, gen_str_array ~loc fs)]
  in
  let opt_pk_sep = match pk_source_fields, sep with
    | _ :: _ :: _, Some s -> [({ txt = Lident "pkSep"; loc }, estr s)]
    | _ -> []
  in
  let opt_sk_fields = match sk_source_fields with
    | [] | [_] -> []
    | fs -> [({ txt = Lident "skFields"; loc }, gen_str_array ~loc fs)]
  in
  let opt_sk_sep = match sk_source_fields, sep with
    | _ :: _ :: _, Some s -> [({ txt = Lident "skSep"; loc }, estr s)]
    | _ -> []
  in
  let opt_auth = match auth with
    | Some (group, auth_table) ->
      [({ txt = Lident "authorization"; loc }, gen_authorization_expr ~loc ~group ~auth_table)]
    | None -> []
  in
  { pexp_desc = Pexp_record (
      required @ opt_id @ opt_sk @ opt_pk_fields @ opt_pk_sep @ opt_sk_fields @ opt_sk_sep @ opt_auth,
      None);
    pexp_loc = loc; pexp_loc_stack = []; pexp_attributes = [] }

(** Generate `let config = config()` or `let config = config(~indexes=[...])`. *)
let gen_config_call ~loc (index_exprs : expression list) =
  let config_fn = { pexp_desc = Pexp_ident { txt = Ldot (Ldot (Lident "Reventless", "ReadModel"), "config"); loc };
                    pexp_loc = loc; pexp_loc_stack = []; pexp_attributes = [] } in
  let call =
    if index_exprs = [] then
      { pexp_desc = Pexp_apply (config_fn, [(Nolabel, Ast_builder.Default.eunit ~loc)]);
        pexp_loc = loc; pexp_loc_stack = []; pexp_attributes = [] }
    else
      let arr = { pexp_desc = Pexp_array index_exprs;
                  pexp_loc = loc; pexp_loc_stack = []; pexp_attributes = [] } in
      { pexp_desc = Pexp_apply (config_fn, [(Labelled "indexes", arr)]);
        pexp_loc = loc; pexp_loc_stack = []; pexp_attributes = [] }
  in
  { pstr_desc = Pstr_value (Nonrecursive, [{
      pvb_pat = { ppat_desc = Ppat_var { txt = "config"; loc };
                  ppat_loc = loc; ppat_loc_stack = []; ppat_attributes = [] };
      pvb_expr = call;
      pvb_attributes = [];
      pvb_loc = loc;
    }]);
    pstr_loc = loc }

(** Collect all @index and @indexSubId annotations from @schema type state fields,
    validate, and generate indexConfig expressions. *)
let collect_index_configs ~loc (fields : label_declaration list) : expression list =
  (* Collect unnamed @index fields — each becomes a standalone index *)
  let unnamed = List.filter_map (fun (ld : label_declaration) ->
    match find_index_attr ld.pld_attributes with
    | Some attr when String.equal (get_index_name attr) "" ->
      let type_ = infer_dynamo_type ld.pld_type in
      let (projection, include_fields, group, auth_table) = get_index_options attr in
      let auth = match group, auth_table with
        | Some g, Some t -> Some (g, t) | _ -> None in
      Some (gen_index_config_expr ~loc
              ~index:ld.pld_name.txt ~type_ ~id_field:None ~sub_id_field:None
              ~pk_source_fields:[] ~sk_source_fields:[] ~sep:None
              ~projection ~include_fields ~auth)
    | _ -> None
  ) fields in
  (* Collect named @index fields grouped by index name, carrying options from the first attr *)
  let named_pks : (string * (string * string) * (string * string list * string option * string option)) list =
    List.filter_map (fun (ld : label_declaration) ->
      match find_index_attr ld.pld_attributes with
      | Some attr ->
        let name = get_index_name attr in
        if String.equal name "" then None
        else
          let type_ = infer_dynamo_type ld.pld_type in
          let opts = get_index_options attr in
          Some (name, (ld.pld_name.txt, type_), opts)
      | None -> None
    ) fields
  in
  (* Collect @indexSubId fields grouped by index name *)
  let named_sks : (string * string) list =
    List.filter_map (fun (ld : label_declaration) ->
      match find_index_sk_attr ld.pld_attributes with
      | Some attr ->
        let name = get_index_name attr in
        if String.equal name "" then
          (Location.raise_errorf ~loc:ld.pld_loc "@indexSubId requires a name: @indexSubId(\"indexName\")")
        else Some (name, ld.pld_name.txt)
      | None -> None
    ) fields
  in
  (* Group named @index fields by index name and build configs *)
  (* Collect unique index names in order of first appearance *)
  let seen = Hashtbl.create 4 in
  let index_names = List.filter_map (fun (name, _, _) ->
    if Hashtbl.mem seen name then None
    else begin Hashtbl.add seen name (); Some name end
  ) named_pks in
  let named_configs = List.map (fun index_name ->
    (* All pk fields for this index name *)
    let pk_fields = List.filter_map (fun (n, info, _) ->
      if String.equal n index_name then Some info else None
    ) named_pks in
    let sk_fields = List.filter_map (fun (n, f) ->
      if String.equal n index_name then Some f else None
    ) named_sks in
    (* Options come from the first @index field for this name *)
    let opts = match List.find_opt (fun (n, _, _) -> String.equal n index_name) named_pks with
      | Some (_, _, o) -> o | None -> ("ALL", [], None, None)
    in
    let (projection, include_fields, group, auth_table) = opts in
    let auth = match group, auth_table with Some g, Some t -> Some (g, t) | _ -> None in
    let (id_field, type_) = match pk_fields with
      | [(field_name, type_)] -> (Some field_name, type_)
      | (_, type_) :: _ ->
        (Some (Printf.sprintf "_%s_pk" index_name), type_)
      | [] -> assert false
    in
    let sub_id_field = match sk_fields with
      | [field_name] -> Some field_name
      | _ :: _ -> Some (Printf.sprintf "_%s_sk" index_name)
      | [] -> None
    in
    let pk_source_fields = List.map fst pk_fields in
    gen_index_config_expr ~loc ~index:index_name ~type_ ~id_field ~sub_id_field
      ~pk_source_fields ~sk_source_fields:sk_fields ~sep:None
      ~projection ~include_fields ~auth
  ) index_names in
  (* Validate: @indexSubId with no matching @index *)
  List.iter (fun (name, _) ->
    if not (List.exists (fun (n, _, _) -> String.equal n name) named_pks) then
      Location.raise_errorf ~loc
        "@indexSubId(\"%s\") has no matching @index(\"%s\")" name name
  ) named_sks;
  unnamed @ named_configs

(** Returns true if the @schema type state record has any @index or @indexSubId annotations. *)
let has_index_annotations (str : structure) : bool =
  match find_schema_state_record str with
  | None -> false
  | Some fields ->
    List.exists (fun (ld : label_declaration) ->
      has_index_field_attr ld.pld_attributes
      || has_index_sk_field_attr ld.pld_attributes
    ) fields

(** Strip @index and @indexSubId attributes from @schema type state record fields. *)
let strip_index_attrs (str : structure) : structure =
  List.map (fun (item : structure_item) ->
    match item.pstr_desc with
    | Pstr_type (rf, decls) ->
      let new_decls = List.map (fun (td : type_declaration) ->
        if not (String.equal td.ptype_name.txt "state"
                && Util.has_attr "schema" td.ptype_attributes) then td
        else
          match td.ptype_kind with
          | Ptype_record fields ->
            let new_fields = List.map (fun (ld : label_declaration) ->
              { ld with pld_attributes = strip_index_field_attrs ld.pld_attributes }
            ) fields in
            { td with ptype_kind = Ptype_record new_fields }
          | _ -> td
      ) decls in
      { item with pstr_desc = Pstr_type (rf, new_decls) }
    | _ -> item
  ) str

(* ── @resolves / @resolvesMany: idResolver/idsResolver config generation ── *)

(** Extract string arguments from an attribute payload of the form
    `@attr({key1: "val1", key2: "val2", ...})`.  Returns an association list.
    Also accepts labeled-call form `@attr(f(~key1="val1", ...))` for symmetry. *)
let get_labeled_string_args (attr : attribute) : (string * string) list =
  match attr.attr_payload with
  | PStr [{ pstr_desc = Pstr_eval (expr, _); _ }] ->
    let collect = function
      | { pexp_desc = Pexp_record (fields, _); _ } ->
        List.filter_map (fun (lid, e) ->
          match lid.txt, e.pexp_desc with
          | Lident k, Pexp_constant (Pconst_string (v, _, _)) -> Some (k, v)
          | _ -> None
        ) fields
      | { pexp_desc = Pexp_apply (_, args); _ } ->
        List.filter_map (fun (lbl, e) ->
          match lbl, e.pexp_desc with
          | Labelled k, Pexp_constant (Pconst_string (v, _, _)) -> Some (k, v)
          | _ -> None
        ) args
      | _ -> []
    in
    collect expr
  | _ -> []

let find_resolves_attr (attrs : attributes) =
  List.find_opt (fun (a : attribute) -> String.equal a.attr_name.txt "resolves") attrs

let find_resolves_many_attr (attrs : attributes) =
  List.find_opt (fun (a : attribute) -> String.equal a.attr_name.txt "resolvesMany") attrs

let strip_resolves_attrs (attrs : attributes) =
  List.filter (fun (attr : attribute) ->
    not (String.equal attr.attr_name.txt "resolves"
         || String.equal attr.attr_name.txt "resolvesMany")
  ) attrs

(** Build a variant constructor expression with an optional string payload.
    `~qualified_path` is a list of module names + ctor, e.g. `["Reventless";"ReadModel";"Index"]`. *)
(** Build `Reventless.ReadModel.CtorName` variant (no payload). *)
let rm_ctor ~loc ctor_name =
  { pexp_desc = Pexp_construct (
      { txt = Ldot (Ldot (Lident "Reventless", "ReadModel"), ctor_name); loc }, None);
    pexp_loc = loc; pexp_loc_stack = []; pexp_attributes = [] }

(** Build `Reventless.ReadModel.CtorName("arg")` variant with a string payload. *)
let rm_ctor_str ~loc ctor_name str_val =
  let payload = Ast_builder.Default.estring ~loc str_val in
  { pexp_desc = Pexp_construct (
      { txt = Ldot (Ldot (Lident "Reventless", "ReadModel"), ctor_name); loc },
      Some payload);
    pexp_loc = loc; pexp_loc_stack = []; pexp_attributes = [] }

(** Build `Reventless.ReadModel.CtorName("a", "b")` variant with a 2-tuple payload. *)
let rm_ctor_str2 ~loc ctor_name a b =
  let tuple = { pexp_desc = Pexp_tuple [
    Ast_builder.Default.estring ~loc a;
    Ast_builder.Default.estring ~loc b;
  ]; pexp_loc = loc; pexp_loc_stack = []; pexp_attributes = [] } in
  { pexp_desc = Pexp_construct (
      { txt = Ldot (Ldot (Lident "Reventless", "ReadModel"), ctor_name); loc },
      Some tuple);
    pexp_loc = loc; pexp_loc_stack = []; pexp_attributes = [] }

(** Generate a `Reventless.ReadModel.idResolverConfig` record expression from
    `@resolves(~table="tableName", ~field="fieldName", ...)` parameters. *)
let gen_id_resolver_expr ~loc ~id_field ~args =
  let estr = Ast_builder.Default.estring ~loc in
  let table_name = List.assoc_opt "table" args |> Option.value ~default:"" in
  let as_field = List.assoc_opt "field" args |> Option.value ~default:"" in
  let via = List.assoc_opt "via" args in
  let plugin = List.assoc_opt "plugin" args in
  let source_sub_id = List.assoc_opt "sourceSubId" args in
  let sub_id_arg = List.assoc_opt "subIdArg" args in
  (* source.subId *)
  let sub_id_expr = match source_sub_id, sub_id_arg with
    | Some f, _ -> rm_ctor_str ~loc "Field" f
    | None, Some a -> rm_ctor_str ~loc "Argument" a
    | None, None -> rm_ctor ~loc "NoSubId"
  in
  (* source.resolvedField *)
  let resolved_field_expr = rm_ctor_str ~loc "Single" as_field in
  (* source record *)
  let source = { pexp_desc = Pexp_record ([
    ({ txt = Lident "idField"; loc }, estr id_field);
    ({ txt = Lident "subId"; loc }, sub_id_expr);
    ({ txt = Lident "resolvedField"; loc }, resolved_field_expr);
  ], None); pexp_loc = loc; pexp_loc_stack = []; pexp_attributes = [] } in
  (* target.idField *)
  let target_id_field = match via with
    | None -> rm_ctor ~loc "Id"
    | Some idx_name -> rm_ctor_str ~loc "Index" idx_name
  in
  (* target record fields *)
  let target_required = [
    ({ txt = Lident "tableName"; loc }, estr table_name);
    ({ txt = Lident "idField"; loc }, target_id_field);
  ] in
  let target_optional = (match plugin with
    | Some p -> [({ txt = Lident "pluginName"; loc }, estr p)]
    | None -> [])
  in
  let target = { pexp_desc = Pexp_record (
    target_required @ target_optional, None);
    pexp_loc = loc; pexp_loc_stack = []; pexp_attributes = [] } in
  (* outer resolveConfig record: { source, target } *)
  { pexp_desc = Pexp_record ([
    ({ txt = Lident "source"; loc }, source);
    ({ txt = Lident "target"; loc }, target);
  ], None); pexp_loc = loc; pexp_loc_stack = []; pexp_attributes = [] }

(** Generate a `Reventless.ReadModel.idsResolverConfig` record expression from
    `@resolvesMany(~table="tableName", ~field="fieldName", ...)` parameters. *)
let gen_ids_resolver_expr ~loc ~ids_field ~args =
  let estr = Ast_builder.Default.estring ~loc in
  let table_name = List.assoc_opt "table" args |> Option.value ~default:"" in
  let as_field = List.assoc_opt "field" args |> Option.value ~default:"" in
  let plugin = List.assoc_opt "plugin" args in
  let source = { pexp_desc = Pexp_record ([
    ({ txt = Lident "idsField"; loc }, estr ids_field);
    ({ txt = Lident "resolvedField"; loc }, estr as_field);
  ], None); pexp_loc = loc; pexp_loc_stack = []; pexp_attributes = [] } in
  let target_required = [({ txt = Lident "tableName"; loc }, estr table_name)] in
  let target_optional = (match plugin with
    | Some p -> [({ txt = Lident "pluginName"; loc }, estr p)]
    | None -> [])
  in
  let target = { pexp_desc = Pexp_record (
    target_required @ target_optional, None);
    pexp_loc = loc; pexp_loc_stack = []; pexp_attributes = [] } in
  { pexp_desc = Pexp_record ([
    ({ txt = Lident "source"; loc }, source);
    ({ txt = Lident "target"; loc }, target);
  ], None); pexp_loc = loc; pexp_loc_stack = []; pexp_attributes = [] }

(** Collect all @resolves annotations and return idResolverConfig expressions. *)
let collect_id_resolver_configs ~loc (fields : label_declaration list) =
  List.filter_map (fun (ld : label_declaration) ->
    match find_resolves_attr ld.pld_attributes with
    | None -> None
    | Some attr ->
      let args = get_labeled_string_args attr in
      Some (gen_id_resolver_expr ~loc ~id_field:ld.pld_name.txt ~args)
  ) fields

(** Collect all @resolvesMany annotations and return idsResolverConfig expressions. *)
let collect_ids_resolver_configs ~loc (fields : label_declaration list) =
  List.filter_map (fun (ld : label_declaration) ->
    match find_resolves_many_attr ld.pld_attributes with
    | None -> None
    | Some attr ->
      let args = get_labeled_string_args attr in
      Some (gen_ids_resolver_expr ~loc ~ids_field:ld.pld_name.txt ~args)
  ) fields

(** Returns true if @schema type state has any @resolves or @resolvesMany annotations. *)
let has_resolver_annotations (str : structure) : bool =
  match find_schema_state_record str with
  | None -> false
  | Some fields ->
    List.exists (fun (ld : label_declaration) ->
      find_resolves_attr ld.pld_attributes <> None
      || find_resolves_many_attr ld.pld_attributes <> None
    ) fields

(** Strip @resolves and @resolvesMany from @schema type state record fields. *)
let strip_resolver_attrs (str : structure) : structure =
  List.map (fun (item : structure_item) ->
    match item.pstr_desc with
    | Pstr_type (rf, decls) ->
      let new_decls = List.map (fun (td : type_declaration) ->
        if not (String.equal td.ptype_name.txt "state"
                && Util.has_attr "schema" td.ptype_attributes) then td
        else
          match td.ptype_kind with
          | Ptype_record fields ->
            let new_fields = List.map (fun (ld : label_declaration) ->
              { ld with pld_attributes = strip_resolves_attrs ld.pld_attributes }
            ) fields in
            { td with ptype_kind = Ptype_record new_fields }
          | _ -> td
      ) decls in
      { item with pstr_desc = Pstr_type (rf, new_decls) }
    | _ -> item
  ) str

(** Extended config call with indexes, idResolvers, idsResolvers. *)
let gen_config_call_full ~loc ~index_exprs ~id_resolver_exprs ~ids_resolver_exprs =
  let config_fn = { pexp_desc = Pexp_ident { txt = Ldot (Ldot (Lident "Reventless", "ReadModel"), "config"); loc };
                    pexp_loc = loc; pexp_loc_stack = []; pexp_attributes = [] } in
  let make_arr exprs =
    { pexp_desc = Pexp_array exprs; pexp_loc = loc; pexp_loc_stack = []; pexp_attributes = [] }
  in
  let args =
    (if index_exprs <> [] then [(Labelled "indexes", make_arr index_exprs)] else [])
    @ (if id_resolver_exprs <> [] then [(Labelled "idResolvers", make_arr id_resolver_exprs)] else [])
    @ (if ids_resolver_exprs <> [] then [(Labelled "idsResolvers", make_arr ids_resolver_exprs)] else [])
  in
  let call = if args = [] then
    { pexp_desc = Pexp_apply (config_fn, [(Nolabel, Ast_builder.Default.eunit ~loc)]);
      pexp_loc = loc; pexp_loc_stack = []; pexp_attributes = [] }
  else
    { pexp_desc = Pexp_apply (config_fn, args);
      pexp_loc = loc; pexp_loc_stack = []; pexp_attributes = [] }
  in
  { pstr_desc = Pstr_value (Nonrecursive, [{
      pvb_pat = { ppat_desc = Ppat_var { txt = "config"; loc };
                  ppat_loc = loc; ppat_loc_stack = []; ppat_attributes = [] };
      pvb_expr = call;
      pvb_attributes = [];
      pvb_loc = loc;
    }]);
    pstr_loc = loc }

(** Generate `let config = config()` or `let config = config(~indexes=[...], ~idResolvers=[...], ~idsResolvers=[...])`.
    Returns a list with one structure item. *)
let generate_config ~loc (str : structure) : structure_item =
  match find_schema_state_record str with
  | None -> gen_config_call ~loc []
  | Some fields ->
    let index_exprs = collect_index_configs ~loc fields in
    let id_resolver_exprs = collect_id_resolver_configs ~loc fields in
    let ids_resolver_exprs = collect_ids_resolver_configs ~loc fields in
    if id_resolver_exprs = [] && ids_resolver_exprs = [] then
      gen_config_call ~loc index_exprs
    else
      gen_config_call_full ~loc ~index_exprs ~id_resolver_exprs ~ids_resolver_exprs

(* ── @hidden / @summary: visibility annotations (no behavioural effect; flow
       through the metadata pipeline so JSON Schema can surface them as
       x-reventless-hidden / x-reventless-summary). ── *)

let has_hidden_field_attr (attrs : attributes) =
  List.exists (fun (attr : attribute) -> String.equal attr.attr_name.txt "hidden") attrs

let has_summary_field_attr (attrs : attributes) =
  List.exists (fun (attr : attribute) -> String.equal attr.attr_name.txt "summary") attrs

let strip_visibility_field_attrs (attrs : attributes) =
  List.filter (fun (attr : attribute) ->
    not (String.equal attr.attr_name.txt "hidden"
         || String.equal attr.attr_name.txt "summary")
  ) attrs

(** Strip @hidden and @summary from @schema type state record fields. *)
let strip_visibility_attrs (str : structure) : structure =
  List.map (fun (item : structure_item) ->
    match item.pstr_desc with
    | Pstr_type (rf, decls) ->
      let new_decls = List.map (fun (td : type_declaration) ->
        if not (String.equal td.ptype_name.txt "state"
                && Util.has_attr "schema" td.ptype_attributes) then td
        else
          match td.ptype_kind with
          | Ptype_record fields ->
            let new_fields = List.map (fun (ld : label_declaration) ->
              { ld with pld_attributes = strip_visibility_field_attrs ld.pld_attributes }
            ) fields in
            { td with ptype_kind = Ptype_record new_fields }
          | _ -> td
      ) decls in
      { item with pstr_desc = Pstr_type (rf, new_decls) }
    | _ -> item
  ) str

(** Validate that no @schema type state field carries both @hidden and @summary. *)
let validate_visibility_annotations (fields : label_declaration list) : unit =
  List.iter (fun (ld : label_declaration) ->
    if has_hidden_field_attr ld.pld_attributes
       && has_summary_field_attr ld.pld_attributes then
      Location.raise_errorf ~loc:ld.pld_loc
        "@hidden and @summary cannot both appear on the same field '%s'"
        ld.pld_name.txt
  ) fields

(* ── @drillTarget / @collapsed: hierarchical rendering hints (no behavioural
       effect; flow through the metadata pipeline so JSON Schema can surface
       them as x-reventless-drillTarget / x-reventless-drillTargetKey /
       x-reventless-collapsed). ── *)

let has_drill_target_field_attr (attrs : attributes) =
  List.exists (fun (attr : attribute) ->
    String.equal attr.attr_name.txt "drillTarget"
  ) attrs

let has_collapsed_field_attr (attrs : attributes) =
  List.exists (fun (attr : attribute) ->
    String.equal attr.attr_name.txt "collapsed"
  ) attrs

let strip_drill_collapsed_field_attrs (attrs : attributes) =
  List.filter (fun (attr : attribute) ->
    not (String.equal attr.attr_name.txt "drillTarget"
         || String.equal attr.attr_name.txt "collapsed")
  ) attrs

(** Strip @drillTarget and @collapsed from @schema type state record fields. *)
let strip_drill_collapsed_attrs (str : structure) : structure =
  List.map (fun (item : structure_item) ->
    match item.pstr_desc with
    | Pstr_type (rf, decls) ->
      let new_decls = List.map (fun (td : type_declaration) ->
        if not (String.equal td.ptype_name.txt "state"
                && Util.has_attr "schema" td.ptype_attributes) then td
        else
          match td.ptype_kind with
          | Ptype_record fields ->
            let new_fields = List.map (fun (ld : label_declaration) ->
              { ld with pld_attributes = strip_drill_collapsed_field_attrs ld.pld_attributes }
            ) fields in
            { td with ptype_kind = Ptype_record new_fields }
          | _ -> td
      ) decls in
      { item with pstr_desc = Pstr_type (rf, new_decls) }
    | _ -> item
  ) str

(** Find the `@drillTarget(...)` attribute on a field, if present. *)
let find_drill_target_attr (attrs : attributes) =
  List.find_opt (fun (a : attribute) ->
    String.equal a.attr_name.txt "drillTarget"
  ) attrs

(** Extract `(sliceName, optional keyPath)` from a `@drillTarget` attribute.
    Accepts either `@drillTarget("SliceName")` (string literal) or
    `@drillTarget({slice: "SliceName", key: "field1/field2"})` (record). *)
let get_drill_target_args (attr : attribute) : (string * string option) =
  match attr.attr_payload with
  | PStr [{ pstr_desc = Pstr_eval ({pexp_desc = Pexp_constant (Pconst_string (s, _, _)); _}, _); _ }] ->
    (s, None)
  | PStr [{ pstr_desc = Pstr_eval ({pexp_desc = Pexp_record (fields, _); _}, _); _ }] ->
    let slice = (match find_record_str "slice" fields with Some s -> s | None -> "") in
    let key = find_record_str "key" fields in
    (slice, key)
  | _ -> ("", None)

(* ── @scan / @scanSort: opt-in for non-indexed fields to participate in
       server-side filter / sort. No behavioural effect at the PPX level —
       flow through the metadata pipeline so JSON Schema can surface them as
       x-reventless-scan / x-reventless-scanSort, and so the GraphQL fragment
       generator can fold the field names into Filter / OrderBy. ── *)

let has_scan_field_attr (attrs : attributes) =
  List.exists (fun (attr : attribute) -> String.equal attr.attr_name.txt "scan") attrs

let has_scan_sort_field_attr (attrs : attributes) =
  List.exists (fun (attr : attribute) -> String.equal attr.attr_name.txt "scanSort") attrs

let strip_scan_field_attrs (attrs : attributes) =
  List.filter (fun (attr : attribute) ->
    not (String.equal attr.attr_name.txt "scan"
         || String.equal attr.attr_name.txt "scanSort")
  ) attrs

(** Strip @scan and @scanSort from @schema type state record fields. *)
let strip_scan_attrs (str : structure) : structure =
  List.map (fun (item : structure_item) ->
    match item.pstr_desc with
    | Pstr_type (rf, decls) ->
      let new_decls = List.map (fun (td : type_declaration) ->
        if not (String.equal td.ptype_name.txt "state"
                && Util.has_attr "schema" td.ptype_attributes) then td
        else
          match td.ptype_kind with
          | Ptype_record fields ->
            let new_fields = List.map (fun (ld : label_declaration) ->
              { ld with pld_attributes = strip_scan_field_attrs ld.pld_attributes }
            ) fields in
            { td with ptype_kind = Ptype_record new_fields }
          | _ -> td
      ) decls in
      { item with pstr_desc = Pstr_type (rf, new_decls) }
    | _ -> item
  ) str

(* ── @semantic / @metric: declared field semantics + dashboard metrics (no
       behavioural effect at the PPX level — flow through the metadata pipeline
       so JSON Schema can surface them as x-reventless-semantic /
       x-reventless-metric, read by AutoUI's annotation + dashboard tiers). ── *)

let find_semantic_attr (attrs : attributes) =
  List.find_opt (fun (a : attribute) -> String.equal a.attr_name.txt "semantic") attrs

let find_metric_attr (attrs : attributes) =
  List.find_opt (fun (a : attribute) -> String.equal a.attr_name.txt "metric") attrs

(** Extract the semantic id string from `@semantic("currency")`. *)
let get_semantic_value ~loc (attr : attribute) : string =
  match attr.attr_payload with
  | PStr [{ pstr_desc = Pstr_eval ({pexp_desc = Pexp_constant (Pconst_string (s, _, _)); _}, _); _ }] -> s
  | _ ->
    Location.raise_errorf ~loc
      "@semantic expects a single string payload, e.g. @semantic(\"currency\")"

(** Extract `(aggregate, label)` from a `@metric` attribute. Accepts either a
    bare string `@metric("sum")` (label defaults to "" — the UI derives one from
    the field name) or a record `@metric({aggregate: "sum", label: "Revenue"})`. *)
let get_metric_value ~loc (attr : attribute) : (string * string) =
  match attr.attr_payload with
  | PStr [{ pstr_desc = Pstr_eval ({pexp_desc = Pexp_constant (Pconst_string (s, _, _)); _}, _); _ }] ->
    (s, "")
  | PStr [{ pstr_desc = Pstr_eval ({pexp_desc = Pexp_record (fields, _); _}, _); _ }] ->
    let aggregate = (match find_record_str "aggregate" fields with Some s -> s | None -> "count") in
    let label = (match find_record_str "label" fields with Some s -> s | None -> "") in
    (aggregate, label)
  | _ ->
    Location.raise_errorf ~loc
      "@metric expects \"sum\" or {aggregate: \"sum\", label: \"Revenue\"}"

let strip_semantic_metric_field_attrs (attrs : attributes) =
  List.filter (fun (attr : attribute) ->
    not (String.equal attr.attr_name.txt "semantic"
         || String.equal attr.attr_name.txt "metric")
  ) attrs

(** Strip @semantic and @metric from @schema type state record fields. *)
let strip_semantic_metric_attrs (str : structure) : structure =
  List.map (fun (item : structure_item) ->
    match item.pstr_desc with
    | Pstr_type (rf, decls) ->
      let new_decls = List.map (fun (td : type_declaration) ->
        if not (String.equal td.ptype_name.txt "state"
                && Util.has_attr "schema" td.ptype_attributes) then td
        else
          match td.ptype_kind with
          | Ptype_record fields ->
            let new_fields = List.map (fun (ld : label_declaration) ->
              { ld with pld_attributes = strip_semantic_metric_field_attrs ld.pld_attributes }
            ) fields in
            { td with ptype_kind = Ptype_record new_fields }
          | _ -> td
      ) decls in
      { item with pstr_desc = Pstr_type (rf, new_decls) }
    | _ -> item
  ) str

(* ── @live: component-level live-updates hint carried on the `@schema type
       state` declaration itself (no behavioural effect at the PPX level — flows
       through the metadata pipeline so JSON Schema can surface it as a
       top-level x-reventless-live bool, read by UI consumers to decide whether
       a live-updates control is offered for the view). ── *)

let find_live_attr (attrs : attributes) =
  List.find_opt (fun (a : attribute) -> String.equal a.attr_name.txt "live") attrs

(** Extract the bool from `@live(true)` / `@live(false)`. Anything else —
    missing payload, non-bool, multiple items — is an arity error. *)
let get_live_value (attr : attribute) : bool =
  match attr.attr_payload with
  | PStr [{ pstr_desc = Pstr_eval ({pexp_desc = Pexp_construct ({ txt = Lident "true"; _ }, None); _}, _); _ }] -> true
  | PStr [{ pstr_desc = Pstr_eval ({pexp_desc = Pexp_construct ({ txt = Lident "false"; _ }, None); _}, _); _ }] -> false
  | _ ->
    Location.raise_errorf ~loc:attr.attr_loc
      "@live expects exactly one bool payload, e.g. @live(false)"

(** Extract `@live(bool)` from the `@schema type state` declaration, if present. *)
let extract_state_live (str : structure) : bool option =
  let rec scan = function
    | [] -> None
    | (item : structure_item) :: rest ->
      (match item.pstr_desc with
       | Pstr_type (_, decls) ->
         let found = List.find_opt (fun (td : type_declaration) ->
           String.equal td.ptype_name.txt "state"
           && Util.has_attr "schema" td.ptype_attributes
         ) decls in
         (match found with
          | Some td ->
            (match find_live_attr td.ptype_attributes with
             | Some attr -> Some (get_live_value attr)
             | None -> None)
          | None -> scan rest)
       | _ -> scan rest)
  in
  scan str

(** Strip @live from the @schema type state type declaration. *)
let strip_live_attrs (str : structure) : structure =
  List.map (fun (item : structure_item) ->
    match item.pstr_desc with
    | Pstr_type (rf, decls) ->
      let new_decls = List.map (fun (td : type_declaration) ->
        if not (String.equal td.ptype_name.txt "state"
                && Util.has_attr "schema" td.ptype_attributes) then td
        else
          { td with ptype_attributes =
              List.filter (fun (a : attribute) ->
                not (String.equal a.attr_name.txt "live")
              ) td.ptype_attributes }
      ) decls in
      { item with pstr_desc = Pstr_type (rf, new_decls) }
    | _ -> item
  ) str

(** Reject `@live` on state declarations of spec files that are not a ReadModel
    or StateViewSlice — without this the annotation would be dropped silently. *)
let check_live_placement (str : structure) : unit =
  List.iter (fun (item : structure_item) ->
    match item.pstr_desc with
    | Pstr_type (_, decls) ->
      List.iter (fun (td : type_declaration) ->
        if String.equal td.ptype_name.txt "state"
           && Util.has_attr "schema" td.ptype_attributes then
          match find_live_attr td.ptype_attributes with
          | Some attr ->
            Location.raise_errorf ~loc:attr.attr_loc
              "@live is only supported on the @schema type state declaration of ReadModel and StateViewSlice spec files"
          | None -> ()
      ) decls
    | _ -> ()
  ) str

(* ── State annotation metadata: propagate structural annotations to JSON Schema ── *)

(** Build a string-array AST expression. *)
let estr_array ~loc strs =
  { pexp_desc = Pexp_array (List.map (Ast_builder.Default.estring ~loc) strs);
    pexp_loc = loc; pexp_loc_stack = []; pexp_attributes = [] }

(** Build a `(string, string)` tuple AST expression. *)
let str_tuple ~loc a b =
  { pexp_desc = Pexp_tuple [
      Ast_builder.Default.estring ~loc a;
      Ast_builder.Default.estring ~loc b;
    ];
    pexp_loc = loc; pexp_loc_stack = []; pexp_attributes = [] }

(** Build an array of `(string, string)` tuples. *)
let str_tuple_array ~loc pairs =
  { pexp_desc = Pexp_array (List.map (fun (a, b) -> str_tuple ~loc a b) pairs);
    pexp_loc = loc; pexp_loc_stack = []; pexp_attributes = [] }

(** Build an array of `(fieldName, {aggregate, label})` tuples for the `metric`
    field of `stateAnnotationSpec`. *)
let metric_tuple_array ~loc pairs =
  let estr = Ast_builder.Default.estring ~loc in
  let one (field, (aggregate, label)) =
    let rec_expr =
      { pexp_desc = Pexp_record (
          [ ({ Location.txt = Lident "aggregate"; loc }, estr aggregate);
            ({ txt = Lident "label"; loc }, estr label) ],
          None);
        pexp_loc = loc; pexp_loc_stack = []; pexp_attributes = [] } in
    { pexp_desc = Pexp_tuple [estr field; rec_expr];
      pexp_loc = loc; pexp_loc_stack = []; pexp_attributes = [] }
  in
  { pexp_desc = Pexp_array (List.map one pairs);
    pexp_loc = loc; pexp_loc_stack = []; pexp_attributes = [] }

(** Build the `let stateSchema = stateSchema->S.Metadata.set(~id=Reventless.StateAnnotations.stateAnnotationsId, spec)`
    shadowing binding. Returns `None` when the state has no structural annotations
    AND no file-level visibility override AND no `@live` declaration. The
    `~visibility` arg is the constructor name extracted from
    `@@reventless.visibility(...)` ("Public" or "Internal"); the default case is
    normalised to `None` upstream so the metadata stays compact. The `~live` arg
    is the bool from `@live(...)` on the state type declaration, or `None` when
    the annotation is absent. *)
let make_state_annotations_binding ~loc ~visibility ~live fields : structure_item option =
  let ids = List.filter_map (fun (ld : label_declaration) ->
    if has_id_field_attr ld.pld_attributes then Some ld.pld_name.txt else None
  ) fields in
  let composite_ids = List.filter_map (fun (ld : label_declaration) ->
    if has_composite_id_field_attr ld.pld_attributes then Some ld.pld_name.txt else None
  ) fields in
  let sub_ids = List.filter_map (fun (ld : label_declaration) ->
    if has_subid_field_attr ld.pld_attributes then Some ld.pld_name.txt else None
  ) fields in
  let composite_sub_ids = List.filter_map (fun (ld : label_declaration) ->
    if has_composite_subid_field_attr ld.pld_attributes then Some ld.pld_name.txt else None
  ) fields in
  let indexes = List.filter_map (fun (ld : label_declaration) ->
    match find_index_attr ld.pld_attributes with
    | Some attr -> Some (ld.pld_name.txt, get_index_name attr)
    | None -> None
  ) fields in
  let hidden = List.filter_map (fun (ld : label_declaration) ->
    if has_hidden_field_attr ld.pld_attributes then Some ld.pld_name.txt else None
  ) fields in
  let summary = List.filter_map (fun (ld : label_declaration) ->
    if has_summary_field_attr ld.pld_attributes then Some ld.pld_name.txt else None
  ) fields in
  let drill_targets = List.filter_map (fun (ld : label_declaration) ->
    match find_drill_target_attr ld.pld_attributes with
    | Some attr ->
      let (slice, _) = get_drill_target_args attr in
      Some (ld.pld_name.txt, slice)
    | None -> None
  ) fields in
  let drill_target_keys = List.filter_map (fun (ld : label_declaration) ->
    match find_drill_target_attr ld.pld_attributes with
    | Some attr ->
      let (_, key_opt) = get_drill_target_args attr in
      (match key_opt with
       | Some key -> Some (ld.pld_name.txt, key)
       | None -> None)
    | None -> None
  ) fields in
  let collapsed = List.filter_map (fun (ld : label_declaration) ->
    if has_collapsed_field_attr ld.pld_attributes then Some ld.pld_name.txt else None
  ) fields in
  let scan = List.filter_map (fun (ld : label_declaration) ->
    if has_scan_field_attr ld.pld_attributes then Some ld.pld_name.txt else None
  ) fields in
  let scan_sort = List.filter_map (fun (ld : label_declaration) ->
    if has_scan_sort_field_attr ld.pld_attributes then Some ld.pld_name.txt else None
  ) fields in
  let semantic = List.filter_map (fun (ld : label_declaration) ->
    match find_semantic_attr ld.pld_attributes with
    | Some attr -> Some (ld.pld_name.txt, get_semantic_value ~loc:ld.pld_loc attr)
    | None -> None
  ) fields in
  let metric = List.filter_map (fun (ld : label_declaration) ->
    match find_metric_attr ld.pld_attributes with
    | Some attr -> Some (ld.pld_name.txt, get_metric_value ~loc:ld.pld_loc attr)
    | None -> None
  ) fields in
  let status_fields = List.filter_map (fun (ld : label_declaration) ->
    if has_status_field_attr ld.pld_attributes then Some (ld.pld_name.txt, ld.pld_loc) else None
  ) fields in
  let status =
    match status_fields with
    | [] -> None
    | [(name, _)] -> Some name
    | (_, _) :: (_, loc2) :: _ ->
      Location.raise_errorf ~loc:loc2
        "duplicate @status annotation; only one field per state record may carry @status"
  in
  let group_by_fields = List.filter_map (fun (ld : label_declaration) ->
    if has_group_by_field_attr ld.pld_attributes then Some (ld.pld_name.txt, ld.pld_loc) else None
  ) fields in
  let group_by =
    match group_by_fields with
    | [] -> None
    | [(name, _)] -> Some name
    | (_, _) :: (_, loc2) :: _ ->
      Location.raise_errorf ~loc:loc2
        "duplicate @groupBy annotation; only one field per state record may carry @groupBy"
  in
  if ids = [] && composite_ids = [] && sub_ids = [] && composite_sub_ids = []
     && indexes = [] && hidden = [] && summary = []
     && drill_targets = [] && drill_target_keys = [] && collapsed = []
     && scan = [] && scan_sort = [] && semantic = [] && metric = []
     && status = None && group_by = None
     && visibility = None && live = None then None
  else
    let ident lid =
      { pexp_desc = Pexp_ident { txt = lid; loc };
        pexp_loc = loc; pexp_loc_stack = []; pexp_attributes = [] } in
    let state_schema_expr = ident (Lident "stateSchema") in
    let metadata_set_expr = ident (Ldot (Ldot (Lident "S", "Metadata"), "set")) in
    let annotations_id_expr =
      ident (Ldot (Ldot (Lident "Reventless", "StateAnnotations"), "stateAnnotationsId")) in
    (* `status: option<string>` is always emitted (None when no @status
       annotation is present). Wrapping in Some/None keeps the AST simple
       and avoids the @res.optional attribute gymnastics that an optional
       (?:) field would require. *)
    let status_value =
      match status with
      | None ->
        { pexp_desc = Pexp_construct ({ txt = Lident "None"; loc }, None);
          pexp_loc = loc; pexp_loc_stack = []; pexp_attributes = [] }
      | Some name ->
        let str_lit =
          { pexp_desc = Pexp_constant (Pconst_string (name, loc, None));
            pexp_loc = loc; pexp_loc_stack = []; pexp_attributes = [] } in
        { pexp_desc = Pexp_construct ({ txt = Lident "Some"; loc }, Some str_lit);
          pexp_loc = loc; pexp_loc_stack = []; pexp_attributes = [] } in
    let group_by_value =
      match group_by with
      | None ->
        { pexp_desc = Pexp_construct ({ txt = Lident "None"; loc }, None);
          pexp_loc = loc; pexp_loc_stack = []; pexp_attributes = [] }
      | Some name ->
        let str_lit =
          { pexp_desc = Pexp_constant (Pconst_string (name, loc, None));
            pexp_loc = loc; pexp_loc_stack = []; pexp_attributes = [] } in
        { pexp_desc = Pexp_construct ({ txt = Lident "Some"; loc }, Some str_lit);
          pexp_loc = loc; pexp_loc_stack = []; pexp_attributes = [] } in
    let visibility_value =
      match visibility with
      | None ->
        { pexp_desc = Pexp_construct ({ txt = Lident "None"; loc }, None);
          pexp_loc = loc; pexp_loc_stack = []; pexp_attributes = [] }
      | Some name ->
        let str_lit =
          { pexp_desc = Pexp_constant (Pconst_string (name, loc, None));
            pexp_loc = loc; pexp_loc_stack = []; pexp_attributes = [] } in
        { pexp_desc = Pexp_construct ({ txt = Lident "Some"; loc }, Some str_lit);
          pexp_loc = loc; pexp_loc_stack = []; pexp_attributes = [] } in
    let live_value =
      match live with
      | None ->
        { pexp_desc = Pexp_construct ({ txt = Lident "None"; loc }, None);
          pexp_loc = loc; pexp_loc_stack = []; pexp_attributes = [] }
      | Some b ->
        let bool_lit =
          { pexp_desc = Pexp_construct ({ txt = Lident (if b then "true" else "false"); loc }, None);
            pexp_loc = loc; pexp_loc_stack = []; pexp_attributes = [] } in
        { pexp_desc = Pexp_construct ({ txt = Lident "Some"; loc }, Some bool_lit);
          pexp_loc = loc; pexp_loc_stack = []; pexp_attributes = [] } in
    let spec_record =
      { pexp_desc = Pexp_record (
          [ ({ Location.txt = Lident "ids"; loc }, estr_array ~loc ids);
            ({ txt = Lident "compositeIds"; loc }, estr_array ~loc composite_ids);
            ({ txt = Lident "subIds"; loc }, estr_array ~loc sub_ids);
            ({ txt = Lident "compositeSubIds"; loc }, estr_array ~loc composite_sub_ids);
            ({ txt = Lident "indexes"; loc }, str_tuple_array ~loc indexes);
            ({ txt = Lident "hidden"; loc }, estr_array ~loc hidden);
            ({ txt = Lident "summary"; loc }, estr_array ~loc summary);
            ({ txt = Lident "drillTargets"; loc }, str_tuple_array ~loc drill_targets);
            ({ txt = Lident "drillTargetKeys"; loc }, str_tuple_array ~loc drill_target_keys);
            ({ txt = Lident "collapsed"; loc }, estr_array ~loc collapsed);
            ({ txt = Lident "scan"; loc }, estr_array ~loc scan);
            ({ txt = Lident "scanSort"; loc }, estr_array ~loc scan_sort);
            ({ txt = Lident "semantic"; loc }, str_tuple_array ~loc semantic);
            ({ txt = Lident "metric"; loc }, metric_tuple_array ~loc metric);
            ({ txt = Lident "status"; loc }, status_value);
            ({ txt = Lident "groupBy"; loc }, group_by_value);
            ({ txt = Lident "visibility"; loc }, visibility_value);
            ({ txt = Lident "live"; loc }, live_value) ],
          None);
        pexp_loc = loc; pexp_loc_stack = []; pexp_attributes = [] } in
    let apply_expr =
      { pexp_desc = Pexp_apply (
          metadata_set_expr,
          [ (Nolabel, state_schema_expr);
            (Labelled "id", annotations_id_expr);
            (Nolabel, spec_record) ]);
        pexp_loc = loc; pexp_loc_stack = []; pexp_attributes = [] } in
    let binding =
      { pvb_pat = { ppat_desc = Ppat_var { txt = "stateSchema"; loc };
                    ppat_loc = loc;
                    ppat_loc_stack = [];
                    ppat_attributes = [] };
        pvb_expr = apply_expr;
        pvb_attributes = [];
        pvb_loc = loc } in
    Some
      { pstr_desc = Pstr_value (Nonrecursive, [binding]);
        pstr_loc = loc }

(** Extracts the constructor name from `@@reventless.visibility(<Case>)`, or
    `None` when absent. Normalises `Public` (the default) to `None` so the
    metadata is only emitted for non-default visibility — keeps the resulting
    JSON Schema compact. *)
let extract_file_visibility (str : structure) : string option =
  match VisibilityInjection.extract_file_value str with
  | None -> None
  | Some expr ->
    (match expr.pexp_desc with
     | Pexp_construct ({ txt = Lident "Public"; _ }, None) -> None
     | Pexp_construct ({ txt = Lident name; _ }, None) -> Some name
     | _ -> None)

(** Returns `[binding]` shadowing `stateSchema` with attached annotation metadata,
    or `[]` when the state record carries no structural annotations and no
    file-level visibility override. Must be called BEFORE the structural and
    visibility attributes are stripped. *)
let generate_state_annotations ~loc (str : structure) : structure_item list =
  match find_schema_state_record str with
  | None -> []
  | Some fields ->
    validate_visibility_annotations fields;
    let visibility = extract_file_visibility str in
    let live = extract_state_live str in
    (match make_state_annotations_binding ~loc ~visibility ~live fields with
     | None -> []
     | Some s -> [s])
