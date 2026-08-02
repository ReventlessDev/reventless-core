open Ppxlib

(** [@offload] field attribute — declares that a field's large value lives in a
    content-addressed object store, carried by reference when big and inline when
    small, and rewrites the field into the [Offload.payload] shape plus the
    matching sury codec.

    Surface:
    {[
      @offload("pluginStructures") structure: option<pluginStructure>
      @offload("catalog.pluginStructures") structure: option<pluginStructure>
      @offload({store: "pluginStructures"}) structure: pluginStructure
    ]}

    emits (for the optional string form):
    {[
      structure:
        @s.matches(Reventless.Offload.optionSchema(~store="pluginStructures", pluginStructureSchema))
        option<Reventless.Offload.payload<pluginStructure>>
    ]}

    and for a non-optional field the [forStore]/[payload] pair without the
    [option] wrapper.

    ## Sibling of {!StorageRefInference}, with two differences

    - [@storageRef] refines an existing [string] and needs no inner schema;
      [@offload]'s codec ({!Offload.optionSchema}/{!Offload.forStore}) round-trips
      through the field's inner value, so this pass must both **rewrite the field
      type** [X] into [Offload.payload<X>] and **synthesise the inner schema
      name** [X] -> [XSchema] (or [t] -> [schema]) by sury convention. Only a
      plain named type ([pluginStructure], [M.t]) can be derived that way; for
      anything else the escape hatch is the hand-written
      [@s.matches(Reventless.Offload.optionSchema(...))] form, and this pass
      raises pointing at it.

    - The record form may carry a per-field [threshold]
      ([@offload({store, threshold: N})]), which becomes the codec call's
      [~threshold]. That marks it on [Semantic.StoredIn] as the top of the
      inline-vs-offloaded precedence chain a client resolves with
      [Offload.effectiveThreshold] (per-field > platform default > 8 KB) before
      calling [Offload.prepare]. The string form carries no threshold.

    Emits the fully-qualified [Reventless.Offload.*] path — [Offload] lives in the
    [reventless-spec] package whose namespace is [Reventless], so this resolves in
    any spec that depends on it, exactly like [@storageRef]'s
    [Reventless.StorageRef.*]. (The [reventless-spec] package's own [Plugin.res]
    cannot see [Reventless] and so hand-writes the helper instead of using this
    shorthand.)

    Runs right after [StorageRefInference.transform_structure] in the spec
    pipeline. *)

let has_offload_attr (attrs : attributes) =
  List.exists (fun (attr : attribute) ->
    String.equal attr.attr_name.txt "offload"
  ) attrs

let strip_offload_attr (attrs : attributes) =
  List.filter (fun (attr : attribute) ->
    not (String.equal attr.attr_name.txt "offload")
  ) attrs

let find_offload_attr (attrs : attributes) =
  List.find_opt (fun (attr : attribute) ->
    String.equal attr.attr_name.txt "offload"
  ) attrs

(* "store" or "plugin.store" -> (store, plugin_opt). *)
let parse_store_string (s : string) : (string * string option) option =
  match String.split_on_char '.' s with
  | [store] -> Some (store, None)
  | [plugin; store] -> Some (store, Some plugin)
  | _ -> None

(* The [threshold] key of a record-form [@offload({store, threshold: N})], if
   present. Only the record form can carry it; the string form never does. *)
let find_record_int key fields =
  match List.find_opt (fun (lid, _) ->
    match lid.txt with Lident k -> String.equal k key | _ -> false
  ) fields with
  | Some (_, { pexp_desc = Pexp_constant (Pconst_integer (s, _)); _ }) ->
    (try Some (int_of_string s) with _ -> None)
  | _ -> None

let get_threshold (attrs : attributes) : int option =
  match find_offload_attr attrs with
  | Some { attr_payload =
             PStr [{ pstr_desc =
                       Pstr_eval ({ pexp_desc = Pexp_record (fields, _); _ }, _); _ }]; _ } ->
    find_record_int "threshold" fields
  | _ -> None

(* Extract [(store, plugin_opt)] from [@offload("store")],
   [@offload("plugin.store")], or [@offload({store: "store"})]. *)
let get_store_target (attrs : attributes) : (string * string option) option =
  match find_offload_attr attrs with
  | None -> None
  | Some attr ->
    (match attr.attr_payload with
     | PStr [{ pstr_desc =
                 Pstr_eval (
                   { pexp_desc = Pexp_constant (Pconst_string (s, _, _)); _ }, _); _ }] ->
       parse_store_string s
     | PStr [{ pstr_desc =
                 Pstr_eval ({ pexp_desc = Pexp_record (fields, _); _ }, _); _ }] ->
       (match StateAnnotations.find_record_str "store" fields with
        | Some s -> parse_store_string s
        | None -> None)
     | _ -> None)

let has_s_matches_attr (attrs : attributes) =
  List.exists (fun (attr : attribute) ->
    String.equal attr.attr_name.txt "s.matches"
  ) attrs

(* Map a type's Longident to its sury schema binding, by sury-ppx convention:
   [t] -> [schema], [foo] -> [fooSchema], preserving any module prefix. *)
let schema_lident_of_type_lident (lid : Longident.t) : Longident.t option =
  let schema_name n = if String.equal n "t" then "schema" else n ^ "Schema" in
  match lid with
  | Lident n -> Some (Lident (schema_name n))
  | Ldot (p, n) -> Some (Ldot (p, schema_name n))
  | Lapply _ -> None

(* If [ct] is already [Offload.payload<X>] (in any of its accepted spellings),
   return the [X]; otherwise [None]. Keeps the pass idempotent when a field is
   pre-wrapped. *)
let payload_inner (ct : core_type) : core_type option =
  match ct.ptyp_desc with
  | Ptyp_constr ({ txt = lid; _ }, [arg]) ->
    (match lid with
     | Lident "payload"
     | Ldot (Lident "Offload", "payload")
     | Ldot (Ldot (Lident "Reventless", "Offload"), "payload") -> Some arg
     | _ -> None)
  | _ -> None

let offload_fn_lident ~is_option =
  let name = if is_option then "optionSchema" else "forStore" in
  Ldot (Ldot (Lident "Reventless", "Offload"), name)

let make_offload_matches_attr ~loc ~store ~plugin_opt ~threshold ~is_option ~inner_schema =
  let fn_expr =
    Ast_builder.Default.pexp_ident ~loc { txt = offload_fn_lident ~is_option; loc }
  in
  let plugin_args =
    match plugin_opt with
    | None -> []
    | Some plugin -> [ (Labelled "plugin", Ast_builder.Default.estring ~loc plugin) ]
  in
  let store_arg = (Labelled "store", Ast_builder.Default.estring ~loc store) in
  let threshold_args =
    match threshold with
    | None -> []
    | Some t -> [ (Labelled "threshold", Ast_builder.Default.eint ~loc t) ]
  in
  let call_expr =
    Ast_builder.Default.pexp_apply ~loc fn_expr
      (plugin_args @ [ store_arg ] @ threshold_args @ [ (Nolabel, inner_schema) ])
  in
  let payload = PStr [{ pstr_desc = Pstr_eval (call_expr, []); pstr_loc = loc }] in
  { attr_name = { txt = "s.matches"; loc }
  ; attr_payload = payload
  ; attr_loc = loc }

let payload_type ~loc ~inner =
  Ast_builder.Default.ptyp_constr ~loc
    { txt = Ldot (Ldot (Lident "Reventless", "Offload"), "payload"); loc }
    [ inner ]

let option_type ~loc ~inner =
  Ast_builder.Default.ptyp_constr ~loc { txt = Lident "option"; loc } [ inner ]

let transform_label_decl (ld : label_declaration) : label_declaration =
  if not (has_offload_attr ld.pld_attributes) then ld
  else begin
    let loc = ld.pld_loc in
    (* The optional per-field cut from @offload({store, threshold: N}); the string
       form carries none. It becomes the codec call's ~threshold, i.e. the top of
       the inline-vs-offloaded precedence chain (Offload.effectiveThreshold). *)
    let threshold = get_threshold ld.pld_attributes in
    match get_store_target ld.pld_attributes with
    | None ->
      Location.raise_errorf ~loc
        "@offload requires a store argument: @offload(\"storeName\"), \
         @offload(\"plugin.storeName\"), or @offload({store: \"storeName\"})"
    | Some (store, plugin_opt) ->
      let clean_attrs = strip_offload_attr ld.pld_attributes in
      (* A manual @s.matches wins: strip the marker but leave the schema alone. *)
      if has_s_matches_attr ld.pld_type.ptyp_attributes then
        { ld with pld_attributes = clean_attrs }
      else begin
        let (is_option, inner0) =
          match ld.pld_type.ptyp_desc with
          | Ptyp_constr ({ txt = Lident "option"; _ }, [ inner ]) -> (true, inner)
          | _ -> (false, ld.pld_type)
        in
        let real_inner =
          match payload_inner inner0 with Some a -> a | None -> inner0
        in
        match real_inner.ptyp_desc with
        | Ptyp_constr ({ txt = lid; _ }, []) ->
          (match schema_lident_of_type_lident lid with
           | None ->
             Location.raise_errorf ~loc
               "@offload cannot derive the inner schema for this field's type; \
                write it by hand: @s.matches(Reventless.Offload.optionSchema(~store=%S, \
                <innerSchema>)) option<Reventless.Offload.payload<...>>" store
           | Some schema_lid ->
             let inner_schema =
               Ast_builder.Default.pexp_ident ~loc { txt = schema_lid; loc }
             in
             let attr =
               make_offload_matches_attr ~loc ~store ~plugin_opt ~threshold ~is_option ~inner_schema
             in
             let payload_ty = payload_type ~loc ~inner:real_inner in
             let new_ty0 =
               if is_option then option_type ~loc ~inner:payload_ty else payload_ty
             in
             let new_ty =
               { new_ty0 with ptyp_attributes = attr :: new_ty0.ptyp_attributes }
             in
             { ld with pld_attributes = clean_attrs; pld_type = new_ty })
        | _ ->
          Location.raise_errorf ~loc
            "@offload can only derive the inner schema for a plain named type \
             (e.g. `pluginStructure` or `M.t`). Write it by hand: \
             @s.matches(Reventless.Offload.optionSchema(~store=%S, <innerSchema>)) \
             option<Reventless.Offload.payload<...>>" store
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
