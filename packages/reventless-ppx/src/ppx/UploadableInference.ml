open Ppxlib

(** Uploadable semantic types — a field typed [UploadableImage.t] /
    [UploadableFile.t] declares both what its value is and which object store it
    lives in, and injects
    [@s.matches(Reventless.UploadableImage.forField(~store="..."))] on the
    field's type expression.

    Surface:
    {[
      productImage: UploadableImage.t                        (* -> productImages *)
      productImage?: UploadableImage.t                       (* -> productImages *)
      productImages: array<UploadableImage.t>                (* -> productImages *)
      @storageRef("catalog.productImagery") productImage: UploadableImage.t
    ]}

    The store is derived from the field name ({!Util.derive_store_name}), so the
    type takes no store argument. An explicit [@storageRef("...")] on an
    uploadable-typed field overrides the derived name and keeps the type's
    semantic — {!StorageRefInference} leaves those fields to this pass rather
    than claiming them, which would downgrade the field to a bare storage ref.

    Modelled on {!StorageRefInference} and ungated for the same reason: this must
    reach command and event records, not only [type state]. *)

let storage_ref_attr = "storageRef"

let strip_storage_ref_attr (attrs : attributes) =
  List.filter
    (fun (attr : attribute) -> not (String.equal attr.attr_name.txt storage_ref_attr))
    attrs

(** [(store, plugin_opt)] from an explicit [@storageRef("store")] /
    [@storageRef("plugin.store")] override, if the field carries one. *)
let get_override (attrs : attributes) : (string * string option) option =
  match Util.find_attr storage_ref_attr attrs with
  | None -> None
  | Some attr -> (
    match Util.get_string_payload attr with
    | None -> None
    | Some s -> (
      match String.split_on_char '.' s with
      | [ store ] -> Some (store, None)
      | [ plugin; store ] -> Some (store, Some plugin)
      | _ -> None))

let has_s_matches_attr (attrs : attributes) =
  List.exists
    (fun (attr : attribute) -> String.equal attr.attr_name.txt "s.matches")
    attrs

(** Builds [@s.matches(Reventless.<Module>.forField(~plugin="P", ~store="S"))]. *)
let make_matches_attr ~loc ~module_name ~store ~plugin_opt =
  let fn_expr =
    Ast_builder.Default.pexp_ident ~loc
      { txt = Ldot (Ldot (Lident "Reventless", module_name), "forField"); loc }
  in
  let plugin_args =
    match plugin_opt with
    | None -> []
    | Some plugin -> [ (Labelled "plugin", Ast_builder.Default.estring ~loc plugin) ]
  in
  let store_arg = (Labelled "store", Ast_builder.Default.estring ~loc store) in
  let call_expr =
    Ast_builder.Default.pexp_apply ~loc fn_expr (plugin_args @ [ store_arg ])
  in
  let payload = PStr [ { pstr_desc = Pstr_eval (call_expr, []); pstr_loc = loc } ] in
  { attr_name = { txt = "s.matches"; loc }; attr_payload = payload; attr_loc = loc }

(** The store this field declares: its explicit override, or its name pluralised.
    A name the rule cannot pluralise is a compile error naming the override, not
    a guess — a wrong store provisions infrastructure nobody meant. *)
let store_for ~loc ~field ~attrs =
  match get_override attrs with
  | Some target -> target
  | None -> (
    match Util.derive_store_name field with
    | Ok store -> (store, None)
    | Error reason ->
      Location.raise_errorf ~loc
        "cannot derive an object store from the field name %S: %s. Name the \
         store explicitly with @storageRef(\"<store>\") on this field."
        field reason)

let transform_label_decl (ld : label_declaration) : label_declaration =
  let loc = ld.pld_loc in
  let field = ld.pld_name.txt in
  match Util.uploadable_module_of_type ld.pld_type with
  | Some module_name ->
    if has_s_matches_attr ld.pld_type.ptyp_attributes then ld
    else
      let store, plugin_opt = store_for ~loc ~field ~attrs:ld.pld_attributes in
      let attr = make_matches_attr ~loc ~module_name ~store ~plugin_opt in
      let new_type =
        { ld.pld_type with ptyp_attributes = attr :: ld.pld_type.ptyp_attributes }
      in
      { ld with
        pld_attributes = strip_storage_ref_attr ld.pld_attributes
      ; pld_type = new_type }
  | None -> (
    (* The array case. The marker goes on the *element* type, because
       [@s.matches] requires the schema's type to match what it is attached to —
       and because a field read for its store is read through
       [StorageRef.getFieldStore], which looks there. Getting this wrong
       provisions nothing, silently. *)
    match Util.array_element ld.pld_type with
    | Some elem -> (
      match Util.uploadable_module_of_type elem with
      | None -> ld
      | Some module_name ->
        if has_s_matches_attr elem.ptyp_attributes then ld
        else
          let store, plugin_opt = store_for ~loc ~field ~attrs:ld.pld_attributes in
          let attr = make_matches_attr ~loc ~module_name ~store ~plugin_opt in
          let new_elem =
            { elem with ptyp_attributes = attr :: elem.ptyp_attributes }
          in
          let arr_lid =
            match ld.pld_type.ptyp_desc with
            | Ptyp_constr (lid, _) -> lid
            | _ -> { txt = Lident "array"; loc }
          in
          let new_type =
            { ld.pld_type with ptyp_desc = Ptyp_constr (arr_lid, [ new_elem ]) }
          in
          { ld with
            pld_attributes = strip_storage_ref_attr ld.pld_attributes
          ; pld_type = new_type })
    | None -> ld)

let transform_constructor (cd : constructor_declaration) : constructor_declaration =
  match cd.pcd_args with
  | Pcstr_record fields ->
    { cd with pcd_args = Pcstr_record (List.map transform_label_decl fields) }
  | _ -> cd

let transform_type_decl (td : type_declaration) : type_declaration =
  match td.ptype_kind with
  | Ptype_record fields ->
    { td with ptype_kind = Ptype_record (List.map transform_label_decl fields) }
  | Ptype_variant constructors ->
    { td with ptype_kind = Ptype_variant (List.map transform_constructor constructors) }
  | _ -> td

let transform_structure (str : structure) : structure =
  List.map
    (fun (item : structure_item) ->
      match item.pstr_desc with
      | Pstr_type (rf, decls) ->
        { item with pstr_desc = Pstr_type (rf, List.map transform_type_decl decls) }
      | _ -> item)
    str
