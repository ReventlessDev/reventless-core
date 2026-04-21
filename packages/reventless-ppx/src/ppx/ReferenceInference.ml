open Ppxlib

(** @ref field attribute — marks a string (or array<string>) field as a
    cross-entity reference and injects
    [@s.matches(Reventless.Reference.to_(...))] on the field's type expression.

    Surface:
    {[
      @ref("Customer") customerId: string
      @ref("Plugin.Customer") customerId: string
      @ref("Customer") customerIds: array<string>
    ]}

    This pass must run before [DcbTagInference.transform_structure] so the
    injected [@s.matches] attribute is seen by the auto-*Id tagger, which skips
    fields that already carry [@s.matches]. *)

let has_ref_field_attr (attrs : attributes) =
  List.exists (fun (attr : attribute) ->
    String.equal attr.attr_name.txt "ref"
  ) attrs

let strip_ref_field_attr (attrs : attributes) =
  List.filter (fun (attr : attribute) ->
    not (String.equal attr.attr_name.txt "ref")
  ) attrs

let has_no_dcb_tag_attr (attrs : attributes) =
  List.exists (fun (attr : attribute) ->
    String.equal attr.attr_name.txt "noDcbTag"
  ) attrs

(** Extracts [(entity, plugin_opt)] from [@ref("Entity")] or
    [@ref("Plugin.Entity")].  Returns [None] when the attribute has no
    string payload (bare [@ref] with no argument). *)
let get_ref_target (attrs : attributes) : (string * string option) option =
  let opt = List.find_opt (fun (attr : attribute) ->
    String.equal attr.attr_name.txt "ref"
  ) attrs in
  match opt with
  | None -> None
  | Some attr ->
    (match attr.attr_payload with
     | PStr [{ pstr_desc =
                 Pstr_eval (
                   { pexp_desc = Pexp_constant (Pconst_string (s, _, _)); _ },
                   _); _ }] ->
       (match String.split_on_char '.' s with
        | [entity] -> Some (entity, None)
        | [plugin; entity] -> Some (entity, Some plugin)
        | _ -> None)
     | _ -> None)

let has_s_matches_attr (attrs : attributes) =
  List.exists (fun (attr : attribute) ->
    String.equal attr.attr_name.txt "s.matches"
  ) attrs

(** Builds [@s.matches(Reventless.Reference.to_(~plugin="P", "Entity"))] or
    [@s.matches(Reventless.Reference.to_("Entity"))], choosing
    [toWithoutDcbTag] when [@noDcbTag] is also present on the field. *)
let make_ref_matches_attr ~loc ~entity ~plugin_opt ~no_dcb =
  let fn_name = if no_dcb then "toWithoutDcbTag" else "to_" in
  let to_expr =
    Ast_builder.Default.pexp_ident ~loc
      { txt = Ldot (Ldot (Lident "Reventless", "Reference"), fn_name); loc }
  in
  let entity_arg = (Nolabel, Ast_builder.Default.estring ~loc entity) in
  let args =
    match plugin_opt with
    | None -> [entity_arg]
    | Some plugin ->
      [ (Labelled "plugin", Ast_builder.Default.estring ~loc plugin)
      ; entity_arg ]
  in
  let call_expr = Ast_builder.Default.pexp_apply ~loc to_expr args in
  let payload =
    PStr [{ pstr_desc = Pstr_eval (call_expr, []); pstr_loc = loc }]
  in
  { attr_name  = { txt = "s.matches"; loc }
  ; attr_payload = payload
  ; attr_loc   = loc }

let is_string_type (ct : core_type) =
  match ct.ptyp_desc with
  | Ptyp_constr ({ txt = Lident "string"; _ }, []) -> true
  | _ -> false

let transform_label_decl (ld : label_declaration) : label_declaration =
  if not (has_ref_field_attr ld.pld_attributes) then ld
  else begin
    let loc = ld.pld_loc in
    match get_ref_target ld.pld_attributes with
    | None ->
      Location.raise_errorf ~loc
        "@ref requires an entity argument: \
         @ref(\"EntityName\") or @ref(\"Plugin.Entity\")"
    | Some (entity, plugin_opt) ->
      let no_dcb     = has_no_dcb_tag_attr ld.pld_attributes in
      let clean_attrs = strip_ref_field_attr ld.pld_attributes in
      let attr = make_ref_matches_attr ~loc ~entity ~plugin_opt ~no_dcb in
      if is_string_type ld.pld_type
         && not (has_s_matches_attr ld.pld_type.ptyp_attributes) then
        let new_type = { ld.pld_type with
                         ptyp_attributes = attr :: ld.pld_type.ptyp_attributes }
        in
        { ld with pld_attributes = clean_attrs; pld_type = new_type }
      else begin
        match ld.pld_type.ptyp_desc with
        | Ptyp_constr ({ txt = Lident "array"; _ } as arr_lid, [elem])
          when is_string_type elem
               && not (has_s_matches_attr elem.ptyp_attributes) ->
          let new_elem =
            { elem with ptyp_attributes = attr :: elem.ptyp_attributes }
          in
          let new_type =
            { ld.pld_type with
              ptyp_desc = Ptyp_constr (arr_lid, [new_elem]) }
          in
          { ld with pld_attributes = clean_attrs; pld_type = new_type }
        | _ ->
          Location.raise_errorf ~loc:ld.pld_loc
            "@ref only supports string and array<string> fields"
      end
  end

let transform_constructor (cd : constructor_declaration)
  : constructor_declaration =
  match cd.pcd_args with
  | Pcstr_record fields ->
    let new_fields = List.map transform_label_decl fields in
    { cd with pcd_args = Pcstr_record new_fields }
  | _ -> cd

let transform_type_decl (td : type_declaration) : type_declaration =
  match td.ptype_kind with
  | Ptype_record fields ->
    let new_fields = List.map transform_label_decl fields in
    { td with ptype_kind = Ptype_record new_fields }
  | Ptype_variant constructors ->
    let new_ctors = List.map transform_constructor constructors in
    { td with ptype_kind = Ptype_variant new_ctors }
  | _ -> td

let transform_structure (str : structure) : structure =
  List.map (fun (item : structure_item) ->
    match item.pstr_desc with
    | Pstr_type (rf, decls) ->
      let new_decls = List.map transform_type_decl decls in
      { item with pstr_desc = Pstr_type (rf, new_decls) }
    | _ -> item
  ) str
