open Ppxlib

(** @owner field attribute — marks the field that ties a row, or a command, to
    the caller who owns it, and injects the matching
    [@s.matches(Reventless.Owner....)] on the field's type expression.

    Surface:
    {[
      @owner customerId: string
      @owner customerId?: string
      @owner customerId: option<string>
      @noDcbTag @owner customerId: string
      @partitionTag @owner customerId: string
    ]}

    Two things separate this from {!ReferenceInference} and
    {!StorageRefInference}, and both are deliberate.

    {b It runs last, after every DCB-tag pass, and it composes instead of
    replacing.} Owner-ness is orthogonal to what else a field declares — it may
    equally be a DCB tag, a partition key, or an entity reference — but a field
    carries at most one [@s.matches]. A pass that ran early and injected
    [Owner.string] would be skipped over by the auto-[*Id] tagger (which passes
    on fields that already carry [@s.matches]), and the field would silently
    lose its tag: a decision read that misses events, reported by nothing.
    Running last, this pass finds whatever schema the field actually resolved to
    and wraps it in [Owner.mark], so [@owner] never subtracts. An author who
    wants the owner field {i not} tagged says so with [@noDcbTag], which by then
    has already left the field bare.

    {b Arrays are rejected rather than annotated.} [Owner.isFieldOwner] follows
    the optional wrapper but deliberately not array elements — one row has one
    owner — so an [@owner ids: array<string>] would annotate a schema no reader
    ever asks about and scope nothing. Refusing it is the difference between a
    compile error and a view that silently serves everybody's rows.

    Requires a [@@reventless.spec] / [@@reventless.behavior] file: outside one,
    no pass runs and the attribute reaches the compiler as an unknown one. *)

let has_owner_attr (attrs : attributes) =
  List.exists (fun (attr : attribute) ->
    String.equal attr.attr_name.txt "owner"
  ) attrs

let strip_owner_attr (attrs : attributes) =
  List.filter (fun (attr : attribute) ->
    not (String.equal attr.attr_name.txt "owner")
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

let owner_lident name = Ldot (Ldot (Lident "Reventless", "Owner"), name)

let make_matches_attr ~loc (expr : expression) =
  { attr_name    = { txt = "s.matches"; loc }
  ; attr_payload = PStr [{ pstr_desc = Pstr_eval (expr, []); pstr_loc = loc }]
  ; attr_loc     = loc }

(** [@s.matches(Reventless.Owner.<name>)] — the bare constructor forms. *)
let owner_constructor_attr ~loc name =
  make_matches_attr ~loc
    (Ast_builder.Default.pexp_ident ~loc { txt = owner_lident name; loc })

(** [@s.matches(Reventless.Owner.mark(<inner>))] — the composing form. *)
let owner_mark_attr ~loc inner =
  let mark =
    Ast_builder.Default.pexp_ident ~loc { txt = owner_lident "mark"; loc }
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
  if not (has_owner_attr ld.pld_attributes) then ld
  else begin
    let loc = ld.pld_loc in
    let clean_attrs = strip_owner_attr ld.pld_attributes in
    let ty = ld.pld_type in
    let apply attr =
      { ld with
        pld_attributes = clean_attrs
      ; pld_type = { ty with
                     ptyp_attributes = attr :: strip_s_matches_attr ty.ptyp_attributes } }
    in
    match existing_matches_expr ty.ptyp_attributes with
    (* The field already resolved to a schema — a DCB tag, a partition key, a
       reference. Wrap it so owning is added to what it says, not substituted
       for it. The type is not re-checked here: whatever produced that schema
       already vouched for the shape, and [mark] is shape-preserving. *)
    | Some inner -> apply (owner_mark_attr ~loc inner)
    (* An [@s.matches] whose payload is not a single expression: [apply] would
       strip it and inject a bare constructor, quietly replacing a schema this
       pass exists not to replace. Say so instead. *)
    | None when List.exists is_s_matches ty.ptyp_attributes ->
      Location.raise_errorf ~loc
        "@owner cannot read the @s.matches on this field, so it cannot compose \
         with it. Write the marker into that schema by hand with \
         Reventless.Owner.mark(<schema>)."
    | None ->
      if is_string_type ty then
        (* Covers [f: string] and [f?: string] alike — the optional form carries
           the bare type plus [@res.optional], and sury wraps the annotated
           schema in [S.option] itself. *)
        apply (owner_constructor_attr ~loc "string")
      else if is_option_string_type ty then
        apply (owner_constructor_attr ~loc "optionString")
      else
        Location.raise_errorf ~loc
          "@owner only supports string and option<string> fields. A row has one \
           owner, so an array field cannot be one; give the owning id its own \
           field."
  end

(** Rejects a second [@owner] in one record or one variant payload.

    Two owners is not a stricter rule than one, it is an unanswered question:
    every reader downstream resolves the owner by taking the first marked field,
    so the second would be inert and the view would scope on whichever field
    declaration order happened to put first. *)
let check_single_owner ~what (fields : label_declaration list) =
  match List.filter (fun (ld : label_declaration) ->
    has_owner_attr ld.pld_attributes) fields
  with
  | first :: (second :: _) ->
    Location.raise_errorf ~loc:second.pld_loc
      "@owner appears twice in %s, on %s and on %s. A record has one owner — \
       the read predicate and the write stamp both need a single field to \
       resolve to."
      what first.pld_name.txt second.pld_name.txt
  | _ -> ()

let transform_constructor (cd : constructor_declaration)
  : constructor_declaration =
  match cd.pcd_args with
  | Pcstr_record fields ->
    check_single_owner ~what:(Printf.sprintf "the payload of %s" cd.pcd_name.txt)
      fields;
    { cd with pcd_args = Pcstr_record (List.map transform_label_decl fields) }
  | _ -> cd

let transform_type_decl (td : type_declaration) : type_declaration =
  match td.ptype_kind with
  | Ptype_record fields ->
    check_single_owner ~what:(Printf.sprintf "type %s" td.ptype_name.txt) fields;
    { td with ptype_kind = Ptype_record (List.map transform_label_decl fields) }
  | Ptype_variant constructors ->
    { td with ptype_kind = Ptype_variant (List.map transform_constructor constructors) }
  | _ -> td

(* Top-level types only, like every sibling field-marker pass. A [module
   Delegate]'s event describes what this component publishes outward, which has
   no owner to scope on. *)
let transform_structure (str : structure) : structure =
  List.map (fun (item : structure_item) ->
    match item.pstr_desc with
    | Pstr_type (rf, decls) ->
      { item with pstr_desc = Pstr_type (rf, List.map transform_type_decl decls) }
    | _ -> item
  ) str
