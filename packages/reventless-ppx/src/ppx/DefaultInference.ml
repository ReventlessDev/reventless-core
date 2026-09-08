open Ppxlib

(** [@default(v)] field attribute — the value a generated form opens the field
    on. Injects [@s.matches(Reventless.FieldDefault.<kind>(<schema>, v))], which
    puts JSON Schema's own [default] keyword on the field.

    {[
      @default(1) quantity: int
      @default("Standard") shippingMethod: string
    ]}

    Runs after {!SensitiveInference} and composes the same way: it wraps whatever
    schema the field resolved to rather than replacing it, so a field that is
    also a tag, an owner or a reference keeps all of it.

    The constructor is picked from the literal's kind, so a default whose type
    does not match the field's is a type error in the generated code rather than
    a check this pass has to make. *)

let attr_is name (attr : attribute) = String.equal attr.attr_name.txt name

let default_payload (attrs : attributes) : expression option =
  match List.find_opt (attr_is "default") attrs with
  | Some { attr_payload = PStr [{ pstr_desc = Pstr_eval (e, _); _ }]; _ } -> Some e
  | _ -> None

let is_s_matches = attr_is "s.matches"

let existing_matches_expr (attrs : attributes) : expression option =
  match List.find_opt is_s_matches attrs with
  | Some { attr_payload = PStr [{ pstr_desc = Pstr_eval (e, _); _ }]; _ } -> Some e
  | _ -> None

(** Which [FieldDefault] constructor a literal asks for. [None] for anything this
    pass cannot name — a variant, a record, a computed expression. *)
let rec constructor_for (e : expression) : string option =
  match e.pexp_desc with
  | Pexp_constant (Pconst_integer _) -> Some "int"
  | Pexp_constant (Pconst_float _) -> Some "float"
  | Pexp_constant (Pconst_string _) -> Some "string"
  | Pexp_construct ({ txt = Lident ("true" | "false"); _ }, None) -> Some "bool"
  (* [-1] parses as a unary application, not as a negative constant. *)
  | Pexp_apply ({ pexp_desc = Pexp_ident { txt = Lident ("~-" | "~-."); _ }; _ },
                [ (Nolabel, inner) ]) -> constructor_for inner
  | _ -> None

(** The schema to wrap where the field carries no [@s.matches] of its own. Only
    the scalars sury names the same way this does; anything else is referred to
    the manual form rather than guessed at. *)
let bare_schema_for ~loc (ct : core_type) : expression option =
  let s name =
    Ast_builder.Default.pexp_ident ~loc { txt = Ldot (Lident "S", name); loc }
  in
  match ct.ptyp_desc with
  | Ptyp_constr ({ txt = Lident "int"; _ }, []) -> Some (s "int")
  | Ptyp_constr ({ txt = Lident "float"; _ }, []) -> Some (s "float")
  | Ptyp_constr ({ txt = Lident "string"; _ }, []) -> Some (s "string")
  | Ptyp_constr ({ txt = Lident "bool"; _ }, []) -> Some (s "bool")
  | _ -> None

let matches_attr ~loc (expr : expression) =
  { attr_name    = { txt = "s.matches"; loc }
  ; attr_payload = PStr [{ pstr_desc = Pstr_eval (expr, []); pstr_loc = loc }]
  ; attr_loc     = loc }

let field_default_attr ~loc ~kind ~schema value =
  let fn =
    Ast_builder.Default.pexp_ident ~loc
      { txt = Ldot (Ldot (Lident "Reventless", "FieldDefault"), kind); loc }
  in
  matches_attr ~loc
    (Ast_builder.Default.pexp_apply ~loc fn [ (Nolabel, schema); (Nolabel, value) ])

let transform_label_decl (ld : label_declaration) : label_declaration =
  match default_payload ld.pld_attributes with
  | None -> ld
  | Some value ->
    let loc = ld.pld_loc in
    let ty = ld.pld_type in
    let kind =
      match constructor_for value with
      | Some k -> k
      | None ->
        Location.raise_errorf ~loc
          "@default takes an int, float, string or bool literal. For any other \
           value write it by hand with \
           @s.matches(Reventless.FieldDefault.mark(<schema>, <json>))."
    in
    let schema =
      match existing_matches_expr ty.ptyp_attributes with
      | Some inner -> inner
      | None ->
        (match bare_schema_for ~loc ty with
         | Some s -> s
         | None ->
           Location.raise_errorf ~loc
             "@default shorthand covers int, float, string and bool. This \
              field's schema is not one this pass can name, so declare it by \
              hand with @s.matches(Reventless.FieldDefault.mark(<schema>, \
              <json>)).")
    in
    { ld with
      pld_attributes = List.filter (fun a -> not (attr_is "default" a)) ld.pld_attributes
    ; pld_type =
        { ty with
          ptyp_attributes =
            field_default_attr ~loc ~kind ~schema value
            :: List.filter (fun a -> not (is_s_matches a)) ty.ptyp_attributes } }

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
  List.map (fun (item : structure_item) ->
    match item.pstr_desc with
    | Pstr_type (rf, decls) ->
      { item with pstr_desc = Pstr_type (rf, List.map transform_type_decl decls) }
    | _ -> item
  ) str
