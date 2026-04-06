open Ppxlib

(** Builds @s.matches(<ident>) on a type expression. *)
let s_matches_attr ~loc ident =
  let payload =
    PStr [{ pstr_desc =
              Pstr_eval (
                { pexp_desc = Pexp_ident { txt = ident; loc };
                  pexp_loc = loc;
                  pexp_loc_stack = [];
                  pexp_attributes = [] },
                []);
            pstr_loc = loc }]
  in
  { attr_name = { txt = "s.matches"; loc };
    attr_payload = payload;
    attr_loc = loc }

let dcb_tag_attr ~loc =
  s_matches_attr ~loc (Ldot (Ldot (Lident "Reventless", "DcbTag"), "string"))

let dcb_partition_attr ~loc =
  s_matches_attr ~loc (Ldot (Ldot (Lident "Reventless", "DcbTag"), "partition"))

let ends_with_ids name =
  let len = String.length name in
  len >= 4
  && name.[len - 1] = 's'
  && name.[len - 2] = 'd'
  && name.[len - 3] = 'I'

let has_s_matches_attr (attrs : attributes) =
  List.exists (fun (attr : attribute) ->
    String.equal attr.attr_name.txt "s.matches"
  ) attrs

let strip_s_matches_attr (attrs : attributes) =
  List.filter (fun (attr : attribute) ->
    not (String.equal attr.attr_name.txt "s.matches")
  ) attrs

(** @partitionTag — marks field as the DcbTag.partition key. *)
let has_partition_tag_field_attr (attrs : attributes) =
  List.exists (fun (attr : attribute) ->
    String.equal attr.attr_name.txt "partitionTag"
  ) attrs

let strip_partition_tag_field_attr (attrs : attributes) =
  List.filter (fun (attr : attribute) ->
    not (String.equal attr.attr_name.txt "partitionTag")
  ) attrs

(** @noTag — suppresses auto-tagging on *Id fields that are not DCB keys. *)
let has_no_tag_field_attr (attrs : attributes) =
  List.exists (fun (attr : attribute) ->
    String.equal attr.attr_name.txt "noTag"
  ) attrs

let strip_no_tag_field_attr (attrs : attributes) =
  List.filter (fun (attr : attribute) ->
    not (String.equal attr.attr_name.txt "noTag")
  ) attrs

(** @dcbTag — explicit opt-in DCB tag for fields that don't follow *Id naming. *)
let has_explicit_dcb_tag_field_attr (attrs : attributes) =
  List.exists (fun (attr : attribute) ->
    String.equal attr.attr_name.txt "dcbTag"
  ) attrs

let strip_explicit_dcb_tag_field_attr (attrs : attributes) =
  List.filter (fun (attr : attribute) ->
    not (String.equal attr.attr_name.txt "dcbTag")
  ) attrs

let is_string_type (ct : core_type) =
  match ct.ptyp_desc with
  | Ptyp_constr ({ txt = Lident "string"; _ }, []) -> true
  | _ -> false

(** Auto-tag pass: only runs in dcbTags-enabled files.
    Skips fields handled by the explicit annotation passes. *)
let transform_label_decl ~loc (ld : label_declaration) =
  if has_partition_tag_field_attr ld.pld_attributes
     || has_no_tag_field_attr ld.pld_attributes
     || has_explicit_dcb_tag_field_attr ld.pld_attributes then ld
  else if Util.ends_with_id ld.pld_name.txt
     && is_string_type ld.pld_type
     && not (has_s_matches_attr ld.pld_type.ptyp_attributes) then
    let attr = dcb_tag_attr ~loc in
    let new_type = { ld.pld_type with
                     ptyp_attributes = attr :: ld.pld_type.ptyp_attributes } in
    { ld with pld_type = new_type }
  else if Util.ends_with_id ld.pld_name.txt || ends_with_ids ld.pld_name.txt then
    (* *Id: array<string> or *Ids: array<string> → annotate inner element type *)
    (match ld.pld_type.ptyp_desc with
     | Ptyp_constr ({ txt = Lident "array"; _ } as arr_lid, [elem])
       when (match elem.ptyp_desc with
             | Ptyp_constr ({ txt = Lident "string"; _ }, []) -> true
             | _ -> false)
            && not (has_s_matches_attr elem.ptyp_attributes) ->
       let attr = dcb_tag_attr ~loc in
       let new_elem = { elem with ptyp_attributes = attr :: elem.ptyp_attributes } in
       let new_type = { ld.pld_type with ptyp_desc = Ptyp_constr (arr_lid, [new_elem]) } in
       { ld with pld_type = new_type }
     | _ -> ld)
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

(* ── Shared walker for unconditional explicit-annotation passes ── *)

let map_schema_fields (f : label_declaration -> label_declaration)
    (str : structure) : structure =
  List.map (fun (item : structure_item) ->
    match item.pstr_desc with
    | Pstr_type (rf, decls) ->
      let new_decls = List.map (fun (td : type_declaration) ->
        if not (Util.has_attr "schema" td.ptype_attributes) then td
        else
          match td.ptype_kind with
          | Ptype_variant constructors ->
            let new_ctors = List.map (fun (cd : constructor_declaration) ->
              match cd.pcd_args with
              | Pcstr_record fields ->
                { cd with pcd_args = Pcstr_record (List.map f fields) }
              | _ -> cd
            ) constructors in
            { td with ptype_kind = Ptype_variant new_ctors }
          | _ -> td
      ) decls in
      { item with pstr_desc = Pstr_type (rf, new_decls) }
    | _ -> item
  ) str

(** @partitionTag → @s.matches(Reventless.DcbTag.partition). Runs unconditionally.
    Strips any existing @s.matches (e.g. auto-applied DcbTag.string) before injecting
    DcbTag.partition, so @partitionTag works correctly on *Id fields in slice folders. *)
let transform_partition_tags ~loc (str : structure) : structure =
  map_schema_fields (fun ld ->
    if has_partition_tag_field_attr ld.pld_attributes
       && is_string_type ld.pld_type then
      { ld with
        pld_type = { ld.pld_type with
                     ptyp_attributes = (dcb_partition_attr ~loc) :: strip_s_matches_attr ld.pld_type.ptyp_attributes };
        pld_attributes = strip_partition_tag_field_attr ld.pld_attributes }
    else ld
  ) str

(** @dcbTag → @s.matches(Reventless.DcbTag.string). Runs unconditionally. *)
let transform_explicit_dcb_tags ~loc (str : structure) : structure =
  map_schema_fields (fun ld ->
    if has_explicit_dcb_tag_field_attr ld.pld_attributes
       && is_string_type ld.pld_type
       && not (has_s_matches_attr ld.pld_type.ptyp_attributes) then
      { ld with
        pld_type = { ld.pld_type with
                     ptyp_attributes = (dcb_tag_attr ~loc) :: ld.pld_type.ptyp_attributes };
        pld_attributes = strip_explicit_dcb_tag_field_attr ld.pld_attributes }
    else ld
  ) str

(** @noTag — strips the field attribute, leaving the type untouched. Runs unconditionally. *)
let strip_no_tag_attrs (str : structure) : structure =
  map_schema_fields (fun ld ->
    if has_no_tag_field_attr ld.pld_attributes then
      { ld with pld_attributes = strip_no_tag_field_attr ld.pld_attributes }
    else ld
  ) str

(* ── @compositePartitionTag pass ── *)

(** Returns true if the field has a @compositePartitionTag attribute. *)
let has_composite_partition_tag_field_attr (attrs : attributes) =
  List.exists (fun (attr : attribute) ->
    String.equal attr.attr_name.txt "compositePartitionTag"
  ) attrs

(** Extracts the separator string from @compositePartitionTag("sep"); defaults to "/". *)
let get_composite_sep (attrs : attributes) =
  let opt = List.find_opt (fun (attr : attribute) ->
    String.equal attr.attr_name.txt "compositePartitionTag"
  ) attrs in
  match opt with
  | None -> "/"
  | Some attr ->
    (match attr.attr_payload with
     | PStr [{ pstr_desc = Pstr_eval ({pexp_desc = Pexp_constant (Pconst_string (s, _, _)); _}, _); _ }] -> s
     | _ -> "/")

let strip_composite_partition_tag_field_attr (attrs : attributes) =
  List.filter (fun (attr : attribute) ->
    not (String.equal attr.attr_name.txt "compositePartitionTag")
  ) attrs

(** Builds @s.matches(Reventless.DcbTag.compositePartitionMember(~position=N, ~sep="S")). *)
let dcb_composite_member_attr ~loc ~position ~sep =
  let dcb_tag_ident = { txt = Ldot (Ldot (Lident "Reventless", "DcbTag"), "compositePartitionMember"); loc } in
  let pos_arg =
    ( Labelled "position",
      Ast_builder.Default.eint ~loc position )
  in
  let sep_arg =
    ( Labelled "sep",
      Ast_builder.Default.estring ~loc sep )
  in
  let call_expr = {
    pexp_desc = Pexp_apply (
      { pexp_desc = Pexp_ident dcb_tag_ident;
        pexp_loc = loc; pexp_loc_stack = []; pexp_attributes = [] },
      [pos_arg; sep_arg]
    );
    pexp_loc = loc;
    pexp_loc_stack = [];
    pexp_attributes = [];
  } in
  let payload = PStr [{ pstr_desc = Pstr_eval (call_expr, []); pstr_loc = loc }] in
  { attr_name = { txt = "s.matches"; loc };
    attr_payload = payload;
    attr_loc = loc }

(** @compositePartitionTag pass.
    Must run after transform_partition_tags to avoid double-transformation.
    Uses a variant-aware walker so position assignment can see all annotated
    fields within a constructor before transforming any of them. *)
let transform_composite_partition_tags ~loc (str : structure) : structure =
  List.map (fun (item : structure_item) ->
    match item.pstr_desc with
    | Pstr_type (rf, decls) ->
      let new_decls = List.map (fun (td : type_declaration) ->
        if not (Util.has_attr "schema" td.ptype_attributes) then td
        else
          match td.ptype_kind with
          | Ptype_variant constructors ->
            let new_ctors = List.map (fun (cd : constructor_declaration) ->
              match cd.pcd_args with
              | Pcstr_record fields ->
                (* Collect indices of fields annotated with @compositePartitionTag *)
                let composite_indices =
                  List.mapi (fun i ld ->
                    if has_composite_partition_tag_field_attr ld.pld_attributes
                       && is_string_type ld.pld_type
                    then Some i
                    else None
                  ) fields
                  |> List.filter_map (fun x -> x)
                in
                if composite_indices = [] then cd
                else begin
                  (* Assign position 0..K-1 in declaration order *)
                  let position_map = List.mapi (fun k idx -> (idx, k)) composite_indices in
                  let new_fields = List.mapi (fun i ld ->
                    match List.assoc_opt i position_map with
                    | None -> ld
                    | Some position ->
                      let sep = get_composite_sep ld.pld_attributes in
                      let composite_attr = dcb_composite_member_attr ~loc ~position ~sep in
                      { ld with
                        pld_type = { ld.pld_type with
                                     ptyp_attributes =
                                       composite_attr :: strip_s_matches_attr ld.pld_type.ptyp_attributes };
                        pld_attributes = strip_composite_partition_tag_field_attr ld.pld_attributes }
                  ) fields in
                  { cd with pcd_args = Pcstr_record new_fields }
                end
              | _ -> cd
            ) constructors in
            { td with ptype_kind = Ptype_variant new_ctors }
          | _ -> td
      ) decls in
      { item with pstr_desc = Pstr_type (rf, new_decls) }
    | _ -> item
  ) str
