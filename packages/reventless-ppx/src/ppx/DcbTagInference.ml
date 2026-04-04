open Ppxlib

let dcb_tag_attr ~loc =
  let payload =
    PStr [{ pstr_desc =
              Pstr_eval (
                { pexp_desc =
                    Pexp_ident { txt = Ldot (Ldot (Lident "Reventless", "DcbTag"), "string"); loc };
                  pexp_loc = loc;
                  pexp_loc_stack = [];
                  pexp_attributes = [] },
                []);
            pstr_loc = loc }]
  in
  { attr_name = { txt = "s.matches"; loc };
    attr_payload = payload;
    attr_loc = loc }

let has_s_matches_attr (attrs : attributes) =
  List.exists (fun (attr : attribute) ->
    String.equal attr.attr_name.txt "s.matches"
  ) attrs

let is_string_type (ct : core_type) =
  match ct.ptyp_desc with
  | Ptyp_constr ({ txt = Lident "string"; _ }, []) -> true
  | _ -> false

let transform_label_decl ~loc (ld : label_declaration) =
  if Util.ends_with_id ld.pld_name.txt
     && is_string_type ld.pld_type
     && not (has_s_matches_attr ld.pld_type.ptyp_attributes) then
    let attr = dcb_tag_attr ~loc in
    let new_type = { ld.pld_type with
                     ptyp_attributes = attr :: ld.pld_type.ptyp_attributes } in
    { ld with pld_type = new_type }
  else
    ld

let transform_constructor ~loc (cd : constructor_declaration) =
  match cd.pcd_args with
  | Pcstr_record fields ->
    let new_fields = List.map (transform_label_decl ~loc) fields in
    { cd with pcd_args = Pcstr_record new_fields }
  | _ -> cd

let transform_type_decl ~loc (td : type_declaration) =
  if not (Util.has_attr "schema" td.ptype_attributes) then td
  else
    match td.ptype_kind with
    | Ptype_variant constructors ->
      let new_ctors = List.map (transform_constructor ~loc) constructors in
      { td with ptype_kind = Ptype_variant new_ctors }
    | _ -> td

let transform_structure ~loc (str : structure) : structure =
  List.map (fun (item : structure_item) ->
    match item.pstr_desc with
    | Pstr_type (rf, decls) ->
      let new_decls = List.map (transform_type_decl ~loc) decls in
      { item with pstr_desc = Pstr_type (rf, new_decls) }
    | _ -> item
  ) str
