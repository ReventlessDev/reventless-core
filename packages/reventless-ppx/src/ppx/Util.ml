open Ppxlib

let has_attr name attrs =
  List.exists (fun (attr : attribute) -> String.equal attr.attr_name.txt name) attrs

let find_attr name attrs =
  List.find_opt (fun (attr : attribute) -> String.equal attr.attr_name.txt name) attrs

let get_string_payload (attr : attribute) =
  match attr.attr_payload with
  | PStr [{ pstr_desc = Pstr_eval ({ pexp_desc = Pexp_constant (Pconst_string (s, _, _)); _ }, _); _ }] ->
    Some s
  | _ -> None

let get_ident_payload (attr : attribute) =
  match attr.attr_payload with
  | PStr [{ pstr_desc = Pstr_eval (expr, _); _ }] ->
    (match expr.pexp_desc with
     | Pexp_construct ({ txt = Lident name; _ }, None) -> Some name
     | Pexp_ident { txt = Lident name; _ } -> Some name
     | _ -> None)
  | _ -> None

let has_let_binding name structure =
  List.exists (fun (item : structure_item) ->
    match item.pstr_desc with
    | Pstr_value (_, bindings) ->
      List.exists (fun (vb : value_binding) ->
        match vb.pvb_pat.ppat_desc with
        | Ppat_var { txt; _ } -> String.equal txt name
        | Ppat_constraint ({ ppat_desc = Ppat_var { txt; _ }; _ }, _) ->
          String.equal txt name
        | _ -> false
      ) bindings
    | _ -> false
  ) structure

let has_module_binding name structure =
  List.exists (fun (item : structure_item) ->
    match item.pstr_desc with
    | Pstr_module mb ->
      (match mb.pmb_name.txt with
       | Some n -> String.equal n name
       | None -> false)
    | _ -> false
  ) structure

let has_open name structure =
  List.exists (fun (item : structure_item) ->
    match item.pstr_desc with
    | Pstr_open od ->
      (match od.popen_expr.pmod_desc with
       | Pmod_ident { txt = Lident n; _ } -> String.equal n name
       | _ -> false)
    | _ -> false
  ) structure

let has_open_dotted outer inner structure =
  List.exists (fun (item : structure_item) ->
    match item.pstr_desc with
    | Pstr_open od ->
      (match od.popen_expr.pmod_desc with
       | Pmod_ident { txt = Ldot (Lident n1, n2); _ } ->
         String.equal n1 outer && String.equal n2 inner
       | _ -> false)
    | _ -> false
  ) structure

let ends_with_id name =
  let len = String.length name in
  len >= 3
  && name.[len - 1] = 'd'
  && name.[len - 2] = 'I'
  && (len = 2 || name.[len - 3] <> 'I')

let strip_suffix s suffix =
  let slen = String.length s in
  let suflen = String.length suffix in
  if slen > suflen && String.sub s (slen - suflen) suflen = suffix then
    String.sub s 0 (slen - suflen)
  else
    s

(* Slice-layer suffixes: describe the category of a slice.
   Stripped everywhere, including inside slice folders. *)
let slice_layer_suffixes = [
  "View"; "Slice"; "Spec"
]

(* Framework component suffixes: describe top-level architectural types.
   Only stripped when the file is NOT inside a slice folder.
   Inside a slice folder these can be part of the entity name (e.g. SyncPlugin). *)
let top_level_only_suffixes = [
  "ExtensionPointMapping";
  "ExtensionPoint";
  "ReadModel";
  "Behavior";
  "Projections";
  "Projection";
  "Aggregate";
  "Plugin";
]

let known_slice_bases = [
  "StateChange"; "StateView"; "Automation";
  "InboundTranslation"; "OutboundTranslation"
]

let ends_with_slice part =
  let len = String.length part in
  len >= 5 && String.sub part (len - 5) 5 = "Slice"

let is_slice_folder_segment part =
  ends_with_slice part || List.mem part known_slice_bases

let is_in_slice_folder fname =
  let dir = Filename.dirname fname in
  let parts = String.split_on_char '/' dir in
  List.exists is_slice_folder_segment parts

let filename_to_name fname =
  let base = Filename.basename fname in
  let without_ext = match String.index_opt base '.' with
    | Some i -> String.sub base 0 i
    | None -> base
  in
  let suffixes =
    if is_in_slice_folder fname then slice_layer_suffixes
    else slice_layer_suffixes @ top_level_only_suffixes
  in
  let rec try_suffixes name = function
    | [] -> name
    | suffix :: rest ->
      let stripped = strip_suffix name suffix in
      if not (String.equal stripped name) then stripped
      else try_suffixes name rest
  in
  try_suffixes without_ext suffixes

let is_extensionpointmapping_filename fname =
  let base = Filename.basename fname in
  let without_ext = match String.index_opt base '.' with
    | Some i -> String.sub base 0 i
    | None -> base
  in
  let sub = "ExtensionPointMapping" in
  let slen = String.length without_ext in
  let sublen = String.length sub in
  let rec check i =
    if i > slen - sublen then false
    else if String.sub without_ext i sublen = sub then true
    else check (i + 1)
  in
  slen >= sublen && check 0

let is_readmodel_filename fname =
  let base = Filename.basename fname in
  let without_ext = match String.index_opt base '.' with
    | Some i -> String.sub base 0 i
    | None -> base
  in
  let sub = "ReadModel" in
  let slen = String.length without_ext in
  let sublen = String.length sub in
  let rec check i =
    if i > slen - sublen then false
    else if String.sub without_ext i sublen = sub then true
    else check (i + 1)
  in
  slen >= sublen && check 0

let is_stateview_filename fname =
  let dir = Filename.dirname fname in
  let parts = String.split_on_char '/' dir in
  List.exists (fun part ->
    let len = String.length part in
    len >= 9 && String.sub part 0 9 = "StateView"
  ) parts

let has_type_binding name (str : structure) =
  List.exists (fun (item : structure_item) ->
    match item.pstr_desc with
    | Pstr_type (_, type_decls) ->
      List.exists (fun (td : type_declaration) ->
        String.equal td.ptype_name.txt name
      ) type_decls
    | _ -> false
  ) str

let has_schema_state_type (str : structure) =
  List.exists (fun (item : structure_item) ->
    match item.pstr_desc with
    | Pstr_type (_, type_decls) ->
      List.exists (fun (td : type_declaration) ->
        String.equal td.ptype_name.txt "state"
        && has_attr "schema" td.ptype_attributes
      ) type_decls
    | _ -> false
  ) str
