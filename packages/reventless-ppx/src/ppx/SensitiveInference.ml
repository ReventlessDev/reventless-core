open Ppxlib

(** @sensitive field attribute — marks a field whose value must not be rendered
    into content a person receives, and injects the matching
    [@s.matches(Reventless.Sensitive....)] on the field's type expression.

    Surface:
    {[
      @sensitive resetToken: string
      @sensitive resetToken?: string
      @sensitive resetToken: option<string>
      @owner customerId: string        (* composes: see below *)
      @dcbTag("sku") @sensitive sku: string
    ]}

    {b It runs last, after every DCB-tag pass and after {!OwnerInference}, and it
    composes instead of replacing.} Sensitivity is orthogonal to what else a
    field declares — it may equally be a DCB tag, an owner, or a reference — but
    a field carries at most one [@s.matches]. A pass that ran early and injected
    [Sensitive.string] would be skipped over by the auto-[*Id] tagger (which
    passes on fields that already carry [@s.matches]), and the field would
    silently lose its tag. Running last, this pass finds whatever schema the
    field actually resolved to and wraps it in [Sensitive.mark], so [@sensitive]
    never subtracts.

    {b More than one field may carry it.} That is the difference from
    {!OwnerInference}, and it is not an oversight: a record has one owner because
    one read predicate resolves to one field, whereas any number of a record's
    values can be things that must not leave. Nothing downstream picks "the"
    sensitive field, so there is no ambiguity to reject.

    {b Types other than string are referred to the manual form.} A field with an
    existing [@s.matches] composes whatever its type — that covers annotated
    records, refs and branded scalars. A bare non-string field has no schema this
    pass can name, and guessing one by convention would be a second, quieter way
    to get a field's shape wrong. The error says what to write instead.

    Requires a [@@reventless.spec] / [@@reventless.behavior] file: outside one,
    no pass runs and the attribute reaches the compiler as an unknown one. *)

let has_sensitive_attr (attrs : attributes) =
  List.exists (fun (attr : attribute) ->
    String.equal attr.attr_name.txt "sensitive"
  ) attrs

let strip_sensitive_attr (attrs : attributes) =
  List.filter (fun (attr : attribute) ->
    not (String.equal attr.attr_name.txt "sensitive")
  ) attrs

let is_s_matches (attr : attribute) =
  String.equal attr.attr_name.txt "s.matches"

(** The expression inside an existing [@s.matches(expr)], if the field has one. *)
let existing_matches_expr (attrs : attributes) : expression option =
  match List.find_opt is_s_matches attrs with
  | None -> None
  | Some attr ->
    (match attr.attr_payload with
     | PStr [{ pstr_desc = Pstr_eval (e, _); _ }] -> Some e
     | _ -> None)

let strip_s_matches_attr (attrs : attributes) =
  List.filter (fun (attr : attribute) -> not (is_s_matches attr)) attrs

let sensitive_lident name =
  Ldot (Ldot (Lident "Reventless", "Sensitive"), name)

let make_matches_attr ~loc (expr : expression) =
  { attr_name    = { txt = "s.matches"; loc }
  ; attr_payload = PStr [{ pstr_desc = Pstr_eval (expr, []); pstr_loc = loc }]
  ; attr_loc     = loc }

(** [@s.matches(Reventless.Sensitive.<name>)] — the bare constructor forms. *)
let sensitive_constructor_attr ~loc name =
  make_matches_attr ~loc
    (Ast_builder.Default.pexp_ident ~loc { txt = sensitive_lident name; loc })

(** [@s.matches(Reventless.Sensitive.mark(<inner>))] — the composing form. *)
let sensitive_mark_attr ~loc inner =
  let mark =
    Ast_builder.Default.pexp_ident ~loc { txt = sensitive_lident "mark"; loc }
  in
  make_matches_attr ~loc
    (Ast_builder.Default.pexp_apply ~loc mark [ (Nolabel, inner) ])

let is_string_type (ct : core_type) =
  match ct.ptyp_desc with
  | Ptyp_constr ({ txt = Lident "string"; _ }, []) -> true
  | _ -> false

let is_option_string_type (ct : core_type) =
  match ct.ptyp_desc with
  | Ptyp_constr ({ txt = Lident "option"; _ }, [ inner ]) -> is_string_type inner
  | _ -> false

let transform_label_decl (ld : label_declaration) : label_declaration =
  if not (has_sensitive_attr ld.pld_attributes) then ld
  else begin
    let loc = ld.pld_loc in
    let clean_attrs = strip_sensitive_attr ld.pld_attributes in
    let ty = ld.pld_type in
    let apply attr =
      { ld with
        pld_attributes = clean_attrs
      ; pld_type = { ty with
                     ptyp_attributes = attr :: strip_s_matches_attr ty.ptyp_attributes } }
    in
    match existing_matches_expr ty.ptyp_attributes with
    (* The field already resolved to a schema — a DCB tag, an owner, a reference.
       Wrap it so sensitivity is added to what it says, not substituted for it.
       The type is not re-checked here: whatever produced that schema already
       vouched for the shape, and [mark] is shape-preserving. *)
    | Some inner -> apply (sensitive_mark_attr ~loc inner)
    (* An [@s.matches] whose payload is not a single expression: [apply] would
       strip it and inject a bare constructor, quietly replacing a schema this
       pass exists not to replace. Say so instead. *)
    | None when List.exists is_s_matches ty.ptyp_attributes ->
      Location.raise_errorf ~loc
        "@sensitive cannot read the @s.matches on this field, so it cannot \
         compose with it. Write the marker into that schema by hand with \
         Reventless.Sensitive.mark(<schema>)."
    | None ->
      if is_string_type ty then
        (* Covers [f: string] and [f?: string] alike — the optional form carries
           the bare type plus [@res.optional], and sury wraps the annotated
           schema in [S.option] itself. *)
        apply (sensitive_constructor_attr ~loc "string")
      else if is_option_string_type ty then
        apply (sensitive_constructor_attr ~loc "optionString")
      else
        Location.raise_errorf ~loc
          "@sensitive shorthand covers string and option<string>. This field's \
           schema is not one this pass can name, so mark it by hand with \
           @s.matches(Reventless.Sensitive.mark(<schema>)) — which composes on \
           any type."
  end

let transform_constructor (cd : constructor_declaration)
  : constructor_declaration =
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

(* Top-level types only, like every sibling field-marker pass. *)
let transform_structure (str : structure) : structure =
  List.map (fun (item : structure_item) ->
    match item.pstr_desc with
    | Pstr_type (rf, decls) ->
      { item with pstr_desc = Pstr_type (rf, List.map transform_type_decl decls) }
    | _ -> item
  ) str
