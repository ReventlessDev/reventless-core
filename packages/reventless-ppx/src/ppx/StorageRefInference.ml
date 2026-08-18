open Ppxlib

(** @storageRef field attribute — declares that a string field holds a reference
    into a named object store, and injects
    [@s.matches(Reventless.StorageRef.forStore(~store="..."))] on the field's
    type expression.

    Surface:
    {[
      @storageRef("productImages") imageUrl: string
      @storageRef("catalog.productImages") imageUrl: string
      @storageRef("productImages") imageUrls: array<string>
    ]}

    Modelled on {!ReferenceInference}, and deliberately ungated with respect to
    the declaring type: this must work on command and event records, not only on
    [type state]. A storage ref is validated where the value is first accepted —
    the command — because that is the last moment before it becomes permanent in
    the event log.

    Unlike [@ref], this injects no DCB tag. A storage ref is not an entity
    reference and does not participate in content-based event routing; the two
    facts are independent and conflating them would misroute.

    Runs before [DcbTagInference.transform_structure] so the injected
    [@s.matches] is seen by the auto-*Id tagger, which skips fields that already
    carry one. *)

let has_storage_ref_attr (attrs : attributes) =
  List.exists (fun (attr : attribute) ->
    String.equal attr.attr_name.txt "storageRef"
  ) attrs

let strip_storage_ref_attr (attrs : attributes) =
  List.filter (fun (attr : attribute) ->
    not (String.equal attr.attr_name.txt "storageRef")
  ) attrs

(** Extracts [(store, plugin_opt)] from [@storageRef("store")] or
    [@storageRef("plugin.store")]. Returns [None] when the attribute carries no
    string payload. *)
let get_store_target (attrs : attributes) : (string * string option) option =
  let opt = List.find_opt (fun (attr : attribute) ->
    String.equal attr.attr_name.txt "storageRef"
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
        | [store] -> Some (store, None)
        | [plugin; store] -> Some (store, Some plugin)
        | _ -> None)
     | _ -> None)

let has_s_matches_attr (attrs : attributes) =
  List.exists (fun (attr : attribute) ->
    String.equal attr.attr_name.txt "s.matches"
  ) attrs

(** Builds [@s.matches(Reventless.StorageRef.forStore(~plugin="P", ~store="S"))]. *)
let make_storage_ref_matches_attr ~loc ~store ~plugin_opt =
  let fn_expr =
    Ast_builder.Default.pexp_ident ~loc
      { txt = Ldot (Ldot (Lident "Reventless", "StorageRef"), "forStore"); loc }
  in
  let plugin_args =
    match plugin_opt with
    | None -> []
    | Some plugin -> [ (Labelled "plugin", Ast_builder.Default.estring ~loc plugin) ]
  in
  let store_arg = (Labelled "store", Ast_builder.Default.estring ~loc store) in
  let call_expr =
    Ast_builder.Default.pexp_apply ~loc fn_expr (plugin_args @ [store_arg])
  in
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

(* An [@storageRef] on an uploadable-typed field is a store *override*, not a
   declaration this pass owns: claiming it would inject [StorageRef.forStore] and
   downgrade the field to a bare ref, losing the semantic its type states.
   [UploadableInference] runs next and consumes the attribute. *)
let is_uploadable_field (ld : label_declaration) =
  match Util.uploadable_module_of_type ld.pld_type with
  | Some _ -> true
  | None -> (
    match Util.array_element ld.pld_type with
    | Some elem -> Util.uploadable_module_of_type elem <> None
    | None -> false)

let transform_label_decl (ld : label_declaration) : label_declaration =
  if not (has_storage_ref_attr ld.pld_attributes) then ld
  else if is_uploadable_field ld then ld
  else begin
    let loc = ld.pld_loc in
    match get_store_target ld.pld_attributes with
    | None ->
      Location.raise_errorf ~loc
        "@storageRef requires a store argument: \
         @storageRef(\"storeName\") or @storageRef(\"plugin.storeName\")"
    | Some (store, plugin_opt) ->
      let clean_attrs = strip_storage_ref_attr ld.pld_attributes in
      if is_string_type ld.pld_type
         && not (has_s_matches_attr ld.pld_type.ptyp_attributes) then
        let attr = make_storage_ref_matches_attr ~loc ~store ~plugin_opt in
        let new_type = { ld.pld_type with
                         ptyp_attributes = attr :: ld.pld_type.ptyp_attributes }
        in
        { ld with pld_attributes = clean_attrs; pld_type = new_type }
      else begin
        match ld.pld_type.ptyp_desc with
        | Ptyp_constr ({ txt = Lident "array"; _ } as arr_lid, [elem])
          when is_string_type elem
               && not (has_s_matches_attr elem.ptyp_attributes) ->
          let attr = make_storage_ref_matches_attr ~loc ~store ~plugin_opt in
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
            "@storageRef only supports string and array<string> fields"
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
