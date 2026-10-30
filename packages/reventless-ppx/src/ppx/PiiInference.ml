open Ppxlib

(** [@pii] field attribute — marks a field whose value is about a person.

    Surface:
    {[
      @pii name: string                         (* subject: the record's @owner field *)
      @pii({subject: "memberId"}) bio?: string  (* subject named *)
      @pii("memberId") photo: UploadableImage.t (* the same, short *)
    ]}

    What it does depends on whose field it is:

    - {b On an event} ([event], [consumedEvent]) the field's type [T] becomes
      [Reventless.Pii.t<T>] and its schema [Reventless.Pii.marked(~subject, …)]:
      the wrapper's codec, the marker the seal and open pass reads, and
      [@sensitive]. An [option<T>] becomes [option<Reventless.Pii.t<T>>], so an
      absent value stays absent. Code that reads the field then says what it does
      when the value is gone.
    - {b On a command} ([command], [inboundCommand], [externalInput],
      [outboundItem]) the type stays and the schema gains the marker and
      [@sensitive] through [Reventless.Pii.mark]: a command is never stored, its
      handler needs the value, and the marker is what keeps it out of a log line.
    - {b On a read model's [state]} it is refused. The deployed projection path
      writes rows without passing them through the schema, so a codec would run
      locally and silently not on AWS. Read models hold plaintext and are swept on
      erasure.

    The value lives in a store when the field's schema is a store reference — an
    [@offload], [@storageRef] or uploadable field, whose passes ran before this
    one. Such a field is marked [forgettable]: erasure deletes the object rather
    than destroying a key. No argument says so; the type does.

    {b Refused}, each with an error that says what to write instead:
    - on a [state];
    - on a DCB tag or partition key — an index key can be neither encrypted nor
      erased, so it must be an opaque id;
    - on an [@owner] field, which is the subject's id, not its data;
    - on a field with no [subject] and no [@owner] sibling to default to,
      outside an aggregate's spec — there the subject is the aggregate, whose
      id the event log seals under;
    - on a field whose subject names no sibling field;
    - on a type whose schema this pass cannot name;
    - on a field of any other type, where it would mark nothing anybody reads.

    {b Order.} After every DCB-tag pass, so it can see that a field became a tag
    and refuse it; before {!OwnerInference}, so the [@owner] attribute it defaults
    the subject to is still on the sibling. It composes with what the field
    already resolved to — an [@offload] or a branded type — rather than replacing
    it. *)

let attr_name = "pii"

let is_pii (attr : attribute) = String.equal attr.attr_name.txt attr_name
let has_pii_attr attrs = List.exists is_pii attrs
let strip_pii_attr attrs = List.filter (fun a -> not (is_pii a)) attrs

let has_attr name attrs =
  List.exists (fun (a : attribute) -> String.equal a.attr_name.txt name) attrs

let is_s_matches (attr : attribute) = String.equal attr.attr_name.txt "s.matches"

let existing_matches_expr (attrs : attributes) : expression option =
  match List.find_opt is_s_matches attrs with
  | Some { attr_payload = PStr [{ pstr_desc = Pstr_eval (e, _); _ }]; _ } -> Some e
  | _ -> None

let strip_s_matches attrs = List.filter (fun a -> not (is_s_matches a)) attrs

(** The subject named in the payload, if any: [@pii("f")] or [@pii({subject: "f"})]. *)
let named_subject ~loc (attrs : attributes) : string option =
  match List.find_opt is_pii attrs with
  | None -> None
  | Some attr ->
    (match attr.attr_payload with
     | PStr [] -> None
     | PStr [{ pstr_desc =
                 Pstr_eval ({ pexp_desc = Pexp_constant (Pconst_string (s, _, _)); _ }, _); _ }] ->
       Some s
     | PStr [{ pstr_desc = Pstr_eval ({ pexp_desc = Pexp_record (fields, _); _ }, _); _ }] ->
       (match StateAnnotations.find_record_str "subject" fields with
        | Some s -> Some s
        | None ->
          Location.raise_errorf ~loc
            "@pii takes a subject: @pii({subject: \"memberId\"}) or @pii(\"memberId\")")
     | _ ->
       Location.raise_errorf ~loc
         "@pii takes no argument, or the field holding the subject's id: \
          @pii({subject: \"memberId\"}) or @pii(\"memberId\")")

let mentions (e : expression) (needle : string) =
  let text = Pprintast.string_of_expression e in
  let n = String.length needle and m = String.length text in
  let rec at i = i + n <= m && (String.equal (String.sub text i n) needle || at (i + 1)) in
  at 0

(** Whose field: the type declaration's name decides. *)
type role = Wraps | Marks | Refused_state | Refused_other of string

let role_of_type_name = function
  | "event" | "consumedEvent" -> Wraps
  | "command" | "inboundCommand" | "externalInput" | "outboundItem" -> Marks
  | "state" -> Refused_state
  | other -> Refused_other other

let pii_lident name = Ldot (Ldot (Lident "Reventless", "Pii"), name)

let ident ~loc lid = Ast_builder.Default.pexp_ident ~loc { txt = lid; loc }

let s_lident name = Ldot (Lident "S", name)

(** The schema of a bare type, by name: the four scalars, then sury's convention
    ([M.t] -> [M.schema], [foo] -> [fooSchema]). [None] for anything else. *)
let schema_of_type ~loc (ct : core_type) : expression option =
  match ct.ptyp_desc with
  | Ptyp_constr ({ txt = Lident ("string" | "int" | "float" | "bool" as n); _ }, []) ->
    Some (ident ~loc (s_lident n))
  | Ptyp_constr ({ txt = lid; _ }, []) ->
    Option.map (ident ~loc) (Util.schema_lident_of_type_lident lid)
  | _ -> None

let pii_type ~loc inner =
  Ast_builder.Default.ptyp_constr ~loc { txt = pii_lident "t"; loc } [ inner ]

let option_type ~loc inner =
  Ast_builder.Default.ptyp_constr ~loc { txt = Lident "option"; loc } [ inner ]

let marker_call ~loc ~fn ~subject ~forgettable inner =
  let args =
    [ (Labelled "subject", Ast_builder.Default.estring ~loc subject) ]
    @ (if forgettable then
         [ (Labelled "forgettable", Ast_builder.Default.ebool ~loc true) ]
       else [])
    @ [ (Nolabel, inner) ]
  in
  Ast_builder.Default.pexp_apply ~loc (ident ~loc (pii_lident fn)) args

let s_option ~loc e =
  Ast_builder.Default.pexp_apply ~loc (ident ~loc (s_lident "option")) [ (Nolabel, e) ]

let matches_attr ~loc e =
  { attr_name = { txt = "s.matches"; loc }
  ; attr_payload = PStr [{ pstr_desc = Pstr_eval (e, []); pstr_loc = loc }]
  ; attr_loc = loc }

let is_forgettable_schema e =
  mentions e "Offload" || mentions e "StorageRef" || mentions e "Uploadable"

let is_tag_schema e = mentions e "DcbTag"

(** The subject an aggregate's events default to: the aggregate itself, whose id
    names the stream and is not a field of the event. The event log reads it and
    seals under the stream's id. Kept in step with [Reventless.Pii.streamSubject]. *)
let stream_subject = "$stream"

let transform_label_decl ~stream ~role ~(siblings : label_declaration list) (ld : label_declaration)
  : label_declaration =
  if not (has_pii_attr ld.pld_attributes) then ld
  else begin
    let loc = ld.pld_loc in
    let field = ld.pld_name.txt in
    (match role with
     | Refused_state ->
       Location.raise_errorf ~loc
         "@pii is refused on a read model's state: a deployed projection writes \
          rows without the schema, so the field would be encrypted locally and \
          not on AWS. Mark the field on the event it is projected from; the read \
          model holds plaintext and is swept on erasure."
     | Refused_other name ->
       Location.raise_errorf ~loc
         "@pii marks a field of an event or a command, not of type %s. Mark the \
          event's (or command's) field that holds this %s." name name
     | Wraps | Marks -> ());
    if has_attr "owner" ld.pld_attributes then
      Location.raise_errorf ~loc
        "@pii cannot mark the @owner field %s: it is the subject's id, which \
         keys their data, not their data." field;
    let ty = ld.pld_type in
    let existing = existing_matches_expr ty.ptyp_attributes in
    (match existing with
     | Some e when is_tag_schema e ->
       Location.raise_errorf ~loc
         "@pii is refused on %s, a DCB tag or partition key: an index key can be \
          neither encrypted nor erased. Tag by an opaque id, carry the personal \
          value in a field of its own, and mark that one." field
     | None when List.exists is_s_matches ty.ptyp_attributes ->
       Location.raise_errorf ~loc
         "@pii cannot read the @s.matches on %s. Write the marker by hand: \
          @s.matches(Reventless.Pii.marked(~subject=\"…\", <schema>))." field
     | _ -> ());
    let subject =
      match named_subject ~loc ld.pld_attributes with
      | Some s ->
        if not (List.exists (fun (s' : label_declaration) -> String.equal s'.pld_name.txt s)
                  siblings) then
          Location.raise_errorf ~loc
            "@pii on %s names the subject %s, which is not a field of this record." field s;
        s
      | None ->
        (match List.find_opt (fun (s' : label_declaration) -> has_attr "owner" s'.pld_attributes)
                 siblings with
         | Some owner -> owner.pld_name.txt
         | None when stream -> stream_subject
         | None ->
           Location.raise_errorf ~loc
             "@pii on %s has no subject: name the field holding the id of the \
              person the value is about, @pii({subject: \"memberId\"}), or mark \
              that field @owner. In an aggregate's spec the subject is the \
              aggregate." field)
    in
    let clean = strip_pii_attr ld.pld_attributes in
    let cannot_name () =
      Location.raise_errorf ~loc
        "@pii cannot name the schema of %s's type. Write it by hand: \
         @s.matches(Reventless.Pii.marked(~subject=%S, <schema>)) on an event, \
         Reventless.Pii.mark on a command." field subject
    in
    let with_type new_ty e =
      { ld with
        pld_attributes = clean
      ; pld_type = { new_ty with
                     ptyp_attributes = matches_attr ~loc e :: strip_s_matches new_ty.ptyp_attributes } }
    in
    match role, existing with
    | Marks, Some e ->
      with_type ty
        (marker_call ~loc ~fn:"mark" ~subject ~forgettable:(is_forgettable_schema e) e)
    | Wraps, Some e ->
      with_type
        { (pii_type ~loc { ty with ptyp_attributes = [] })
          with ptyp_attributes = ty.ptyp_attributes }
        (marker_call ~loc ~fn:"marked" ~subject ~forgettable:(is_forgettable_schema e) e)
    | (Refused_state | Refused_other _), _ -> ld (* raised above *)
    | (Marks | Wraps), None ->
      let (is_option, inner) =
        match ty.ptyp_desc with
        | Ptyp_constr ({ txt = Lident "option"; _ }, [ inner ]) -> (true, inner)
        | _ -> (false, ty)
      in
      (match schema_of_type ~loc inner with
       | None -> cannot_name ()
       | Some inner_schema ->
         (match role with
          | Marks ->
            let schema = if is_option then s_option ~loc inner_schema else inner_schema in
            with_type ty (marker_call ~loc ~fn:"mark" ~subject ~forgettable:false schema)
          | _ ->
            let marked =
              marker_call ~loc ~fn:"marked" ~subject ~forgettable:false inner_schema
            in
            if is_option then
              with_type
                { ty with ptyp_desc = (option_type ~loc (pii_type ~loc inner)).ptyp_desc }
                (s_option ~loc marked)
            else
              with_type { ty with ptyp_desc = (pii_type ~loc inner).ptyp_desc } marked))
  end

let transform_fields ~stream ~role fields =
  List.map (transform_label_decl ~stream ~role ~siblings:fields) fields

let transform_type_decl ~stream (td : type_declaration) : type_declaration =
  let role = role_of_type_name td.ptype_name.txt in
  match td.ptype_kind with
  | Ptype_record fields -> { td with ptype_kind = Ptype_record (transform_fields ~stream ~role fields) }
  | Ptype_variant ctors ->
    { td with
      ptype_kind =
        Ptype_variant
          (List.map (fun (cd : constructor_declaration) ->
             match cd.pcd_args with
             | Pcstr_record fields ->
               { cd with pcd_args = Pcstr_record (transform_fields ~stream ~role fields) }
             | _ -> cd) ctors) }
  | _ -> td

(* Top-level types only, like every sibling field-marker pass. [stream] is set for
   an aggregate's spec, where a field with no subject is about the aggregate. *)
let transform_structure ?(stream = false) (str : structure) : structure =
  List.map (fun (item : structure_item) ->
    match item.pstr_desc with
    | Pstr_type (rf, decls) ->
      { item with pstr_desc = Pstr_type (rf, List.map (transform_type_decl ~stream) decls) }
    | _ -> item
  ) str
