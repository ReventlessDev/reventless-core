open Ppxlib

(** @displayName field attribute — one or more fields can carry it; values are
    composed into a projected [displayName] column by the runtime.

    Surface:
    {[
      @schema type state = {
        id: string,
        @displayName firstName: string,
        @displayName lastName: string,
      }
    ]}

    This pass strips the attribute from the annotated fields, injects a synthetic
    [displayName: string] record field, and emits a shadowing
    [let stateSchema = stateSchema->S.Metadata.set(...)] binding that attaches
    the [Reventless.DisplayName.displayNameSpec] to the sury schema. *)

let has_display_name_field_attr (attrs : attributes) =
  List.exists (fun (attr : attribute) ->
    String.equal attr.attr_name.txt "displayName"
  ) attrs

let strip_display_name_field_attr (attrs : attributes) =
  List.filter (fun (attr : attribute) ->
    not (String.equal attr.attr_name.txt "displayName")
  ) attrs

(** Extracts the separator from [@displayName("sep")]; returns [None] when the
    annotation has no payload. *)
let get_display_name_sep (attrs : attributes) : string option =
  let opt = List.find_opt (fun (attr : attribute) ->
    String.equal attr.attr_name.txt "displayName"
  ) attrs in
  match opt with
  | None -> None
  | Some attr ->
    (match attr.attr_payload with
     | PStr [{ pstr_desc = Pstr_eval ({pexp_desc = Pexp_constant (Pconst_string (s, _, _)); _}, _); _ }] -> Some s
     | _ -> None)

let is_string_type (ct : core_type) =
  match ct.ptyp_desc with
  | Ptyp_constr ({ txt = Lident "string"; _ }, []) -> true
  | _ -> false

let is_option_string_type (ct : core_type) =
  match ct.ptyp_desc with
  | Ptyp_constr ({ txt = Lident "option"; _ }, [inner]) -> is_string_type inner
  | _ -> false

(** The injected field is [displayName?: string] — optional at construction time so
    projection bodies that call [Create] / [Set] / etc. on the state record do not
    need to provide a placeholder. The projection runtime fills it on every write.

    ReScript represents [field?: T] in the AST as [field: option<T>] carrying the
    [@res.optional] field-level attribute; sury-ppx then emits [S.option(...)] for
    the schema, and [SchemaType.fromSury] renders that as nullable in GraphQL. *)
(** ReScript's native [field?: string] parses as [pld_type = string] (plain, not
    wrapped) plus a [@res.optional] attribute on [pld_attributes]. The attribute
    alone makes the field optional at construction while sury-ppx sees it and
    emits [S.option(...)] for the schema.

    Empirical note: the ReScript type-checker rejects the optional attribute
    when the [pld_name] / [pld_type] / [pld_loc] / [attr_loc] locations are
    all identical (as is the default when a ppx synthesises a field from one
    [~loc]). Use [Location.none] for the synthetic field's locations so the
    checker treats it as a pure "ghost" field and honours the attribute. *)
let make_synthetic_display_name_field ~loc:_ : label_declaration =
  let ghost = Location.none in
  let res_optional_attr =
    { attr_name = { txt = "res.optional"; loc = ghost };
      attr_payload = PStr [];
      attr_loc = ghost } in
  let string_ct =
    { ptyp_desc = Ptyp_constr ({ txt = Lident "string"; loc = ghost }, []);
      ptyp_loc = ghost;
      ptyp_loc_stack = [];
      ptyp_attributes = [] } in
  { pld_name = { txt = "displayName"; loc = ghost };
    pld_mutable = Immutable;
    pld_type = string_ct;
    pld_loc = ghost;
    pld_attributes = [res_optional_attr] }

(** Builds [let stateSchema = stateSchema->S.Metadata.set(~id=Reventless.DisplayName.displayNameId, { fields: [..], separator: "s" })]. *)
let make_metadata_stri ~loc ~fields ~separator : structure_item =
  let ident ~loc lid =
    { pexp_desc = Pexp_ident { txt = lid; loc };
      pexp_loc = loc;
      pexp_loc_stack = [];
      pexp_attributes = [] } in
  let state_schema_expr = ident ~loc (Lident "stateSchema") in
  let metadata_set_expr = ident ~loc (Ldot (Ldot (Lident "S", "Metadata"), "set")) in
  let display_name_id_expr =
    ident ~loc (Ldot (Ldot (Lident "Reventless", "DisplayName"), "displayNameId")) in
  let fields_array =
    Ast_builder.Default.pexp_array ~loc
      (List.map (fun name -> Ast_builder.Default.estring ~loc name) fields) in
  let separator_expr = Ast_builder.Default.estring ~loc separator in
  let record_expr =
    { pexp_desc = Pexp_record (
        [ ({ txt = Lident "fields"; loc }, fields_array);
          ({ txt = Lident "separator"; loc }, separator_expr) ],
        None);
      pexp_loc = loc;
      pexp_loc_stack = [];
      pexp_attributes = [] } in
  let apply_expr =
    { pexp_desc = Pexp_apply (
        metadata_set_expr,
        [ (Nolabel, state_schema_expr);
          (Labelled "id", display_name_id_expr);
          (Nolabel, record_expr) ]);
      pexp_loc = loc;
      pexp_loc_stack = [];
      pexp_attributes = [] } in
  let binding =
    { pvb_pat = { ppat_desc = Ppat_var { txt = "stateSchema"; loc };
                  ppat_loc = loc;
                  ppat_loc_stack = [];
                  ppat_attributes = [] };
      pvb_expr = apply_expr;
      pvb_attributes = [];
      pvb_loc = loc } in
  { pstr_desc = Pstr_value (Nonrecursive, [binding]);
    pstr_loc = loc }

let is_schema_state (td : type_declaration) =
  String.equal td.ptype_name.txt "state"
  && Util.has_attr "schema" td.ptype_attributes

(** Transforms a [@schema type state] record declaration, returning the new
    declaration and any extra structure items (the metadata shadowing binding)
    that should be emitted after it. *)
let transform_state_record ~loc (td : type_declaration)
  : (type_declaration * structure_item list) =
  match td.ptype_kind with
  | Ptype_record fields ->
    let collected = List.filter_map (fun (ld : label_declaration) ->
      if has_display_name_field_attr ld.pld_attributes then begin
        if not (is_string_type ld.pld_type || is_option_string_type ld.pld_type) then
          Location.raise_errorf ~loc:ld.pld_loc
            "@displayName only supports string and option<string> fields";
        Some (ld.pld_name.txt, get_display_name_sep ld.pld_attributes)
      end else
        None
    ) fields in
    (match collected with
     | [] -> (td, [])
     | _ ->
       let field_names = List.map fst collected in
       let separator =
         List.fold_left (fun acc (_, sep) ->
           match sep with Some s -> s | None -> acc) " " collected in
       let cleaned_fields = List.map (fun (ld : label_declaration) ->
         { ld with pld_attributes = strip_display_name_field_attr ld.pld_attributes }
       ) fields in
       let new_fields = cleaned_fields @ [make_synthetic_display_name_field ~loc] in
       let new_td = { td with ptype_kind = Ptype_record new_fields } in
       let metadata_stri = make_metadata_stri ~loc ~fields:field_names ~separator in
       (new_td, [metadata_stri]))
  | _ -> (td, [])

(** Walks the structure, rewriting each [@schema type state] record and emitting
    the metadata-shadowing binding immediately after each transformed type-decl item. *)
let transform_structure (str : structure) : structure =
  List.concat_map (fun (item : structure_item) ->
    match item.pstr_desc with
    | Pstr_type (rf, decls) ->
      let extras = ref [] in
      let new_decls = List.map (fun (td : type_declaration) ->
        if is_schema_state td then begin
          let (new_td, emitted) = transform_state_record ~loc:td.ptype_loc td in
          extras := !extras @ emitted;
          new_td
        end else td
      ) decls in
      let new_item = { item with pstr_desc = Pstr_type (rf, new_decls) } in
      new_item :: !extras
    | _ -> [item]
  ) str
