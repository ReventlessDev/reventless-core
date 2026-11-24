open Ppxlib

(** @issued field attribute — marks the command field whose reference code the
    platform makes, and injects [@s.matches(Reventless.ReferenceCode.issued)].

    Surface:
    {[
      @issued chargingToken: Reventless.ReferenceCode.t
      @issued chargingToken: ReferenceCode.t
    ]}

    Runs after every DCB-tag pass and after {!OwnerInference}, and composes the
    way that pass does: a field that already resolved to a schema keeps it,
    wrapped in [ReferenceCode.markIssued]. Only a field typed [ReferenceCode.t]
    may carry it: the platform makes a reference code and nothing else, and a
    marker on another type would fill a field with a value of the wrong kind. *)

let has_issued_attr (attrs : attributes) =
  List.exists (fun (attr : attribute) -> String.equal attr.attr_name.txt "issued") attrs

let strip_issued_attr (attrs : attributes) =
  List.filter (fun (attr : attribute) -> not (String.equal attr.attr_name.txt "issued")) attrs

let reference_code_lident name = Ldot (Ldot (Lident "Reventless", "ReferenceCode"), name)

let is_reference_code (ct : core_type) =
  match Util.branded_string_module ct with
  | Some "ReferenceCode" -> true
  | _ -> false

let transform_label_decl (ld : label_declaration) : label_declaration =
  if not (has_issued_attr ld.pld_attributes) then ld
  else begin
    let loc = ld.pld_loc in
    let ty = ld.pld_type in
    if not (is_reference_code ty) then
      Location.raise_errorf ~loc
        "@issued marks a field the platform fills with a reference code, so the field must be \
         typed Reventless.ReferenceCode.t."
    else
      let expr =
        match OwnerInference.existing_matches_expr ty.ptyp_attributes with
        | Some inner ->
          Ast_builder.Default.pexp_apply ~loc
            (Ast_builder.Default.pexp_ident ~loc { txt = reference_code_lident "markIssued"; loc })
            [ (Nolabel, inner) ]
        | None ->
          Ast_builder.Default.pexp_ident ~loc { txt = reference_code_lident "issued"; loc }
      in
      { ld with
        pld_attributes = strip_issued_attr ld.pld_attributes
      ; pld_type = { ty with
                     ptyp_attributes =
                       OwnerInference.make_matches_attr ~loc expr
                       :: OwnerInference.strip_s_matches_attr ty.ptyp_attributes } }
  end

let transform_type_decl (td : type_declaration) : type_declaration =
  match td.ptype_kind with
  | Ptype_record fields ->
    { td with ptype_kind = Ptype_record (List.map transform_label_decl fields) }
  | Ptype_variant constructors ->
    { td with
      ptype_kind =
        Ptype_variant
          (List.map (fun (cd : constructor_declaration) ->
             match cd.pcd_args with
             | Pcstr_record fields ->
               { cd with pcd_args = Pcstr_record (List.map transform_label_decl fields) }
             | _ -> cd)
             constructors) }
  | _ -> td

let transform_structure (str : structure) : structure =
  List.map (fun (item : structure_item) ->
    match item.pstr_desc with
    | Pstr_type (rf, decls) ->
      { item with pstr_desc = Pstr_type (rf, List.map transform_type_decl decls) }
    | _ -> item
  ) str
