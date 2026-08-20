open Ppxlib

(** A variant used as a field of a queryable's [state] — one fact with several
    shapes, rather than several fields nothing keeps in step.

    {[
      @schema
      type geolocation =
        | Pending({requestedFor: string})
        | Located({point: Reventless.GeoPoint.t})
        | Unresolvable({reason: string})

      @schema
      type state = {customerId: string, geolocation: geolocation}
    ]}

    Two things happen here, and neither is optional for the field to work.

    {b The union is named.} The SDL emitter reaches a field through a path and
    the write path has only the schema in hand, so the name both must agree on is
    carried on the schema: this pass emits
    [let geolocationSchema = Reventless.TaggedUnion.named(~name="…", geolocationSchema)]
    immediately after the declaration, where it shadows what sury-ppx generates
    from it and is what [type state] then closes over. Without a name the field
    is emitted as [String] — the behaviour that predates the marker, now reported
    at deploy time rather than silent.

    The name is [<Plugin>_<Spec><Type>], which is what the enum beside it is
    already called. It is deliberately not derived from the field path: two
    fields holding the same union hold the same type, and a per-field name is
    what produced six copies of ISO 4217 in one schema before
    [semanticCompositeNames] existed.

    {b Three arm shapes are refused,} all of which compile, encode and decode
    perfectly well, and all for reasons that are GraphQL's:

    - a payload-less arm ([| Pending]) is the bare string ["Pending"] on the
      wire, and a union member must be an object type;
    - an empty inline record ([| Pending({})]) is an object, but the member type
      it implies has zero fields, which is invalid;
    - a positional payload ([| Located(GeoPoint.t)]) publishes the compiler's
      [_0] as an SDL field name and as a stored key.

    An enum — every arm payload-less — is untouched: that is a different type
    with a different emission, and the whole of this pass keys off a union having
    at least one arm that carries something.

    Command and event variants are untouched too. They are decomposed into one
    mutation per constructor, so a payload-less [Deactivate] stays exactly as it
    is; only a union used as *state* has to become a GraphQL type. *)

type ctor_shape = Named | Bare | Empty | Positional

let shape_of (cd : constructor_declaration) : ctor_shape =
  match cd.pcd_args with
  | Pcstr_record [] -> Empty
  | Pcstr_record _ -> Named
  | Pcstr_tuple [] -> Bare
  | Pcstr_tuple _ -> Positional

let is_payload_union (ctors : constructor_declaration list) =
  List.exists (fun cd -> shape_of cd <> Bare) ctors

type union_decl = {
  u_type : string;
  u_ctors : constructor_declaration list;
}

let schema_variants (str : structure) : union_decl list =
  List.concat_map (fun (item : structure_item) ->
    match item.pstr_desc with
    | Pstr_type (_, decls) ->
      List.filter_map (fun (td : type_declaration) ->
        if not (Util.has_attr "schema" td.ptype_attributes) then None
        else
          match td.ptype_kind with
          | Ptype_variant ctors -> Some { u_type = td.ptype_name.txt; u_ctors = ctors }
          | _ -> None
      ) decls
    | _ -> []
  ) str

(** The local type a field ultimately holds, through the wrappers that keep the
    element's identity: [option<t>], [array<t>] and [list<t>] all hold [t]. A
    qualified or applied type names something this per-file pass cannot see the
    declaration of, and is left alone. *)
let rec referenced_type_name (ct : core_type) : string option =
  match ct.ptyp_desc with
  | Ptyp_constr ({ txt = Lident ("option" | "array" | "list"); _ }, [ inner ]) ->
    referenced_type_name inner
  | Ptyp_constr ({ txt = Lident name; _ }, []) -> Some name
  | _ -> None

(** The [@schema type state] fields that hold a locally-declared payload union,
    paired with the declaration each one holds. *)
let state_union_fields (str : structure)
  : (label_declaration * union_decl) list =
  match StateAnnotations.find_schema_state_record str with
  | None -> []
  | Some fields ->
    let variants = schema_variants str in
    List.filter_map (fun (ld : label_declaration) ->
      match referenced_type_name ld.pld_type with
      | None -> None
      | Some type_name ->
        (match List.find_opt (fun u -> String.equal u.u_type type_name) variants with
         | Some u when is_payload_union u.u_ctors -> Some (ld, u)
         | _ -> None)
    ) fields

(* Annotations that build a key, a filter, a sort or a predicate. Every one of
   them ends up comparing the field to a scalar: `deriveServerCapability` emits
   `<field>Eq: String` against a value that is an object, and a retirement
   predicate compares an arm name to a stored record — which does not match, so
   the rows are never withdrawn and nothing reports it.

   `@hidden`, `@summary` and `@displayName` are absent on purpose: they describe
   how a field is shown, which a union field can be. *)
let refused_field_attrs =
  [ "id"; "compositeId"; "subId"; "compositeSubId";
    "index"; "indexSubId"; "scan"; "scanSort";
    "groupBy"; "lifecycle"; "retired" ]

let arm_error ~field ~type_name (cd : constructor_declaration) (shape : ctor_shape) =
  let carries =
    match shape with
    | Bare -> "no payload, so sury writes it as the bare string \"" ^ cd.pcd_name.txt ^ "\""
    | Empty -> "an empty inline record, so the member type it implies has no fields"
    | Positional ->
      "a positional payload, so its field is published under the compiler's name `_0`"
    | Named -> "" (* unreachable *)
  in
  Location.raise_errorf ~loc:cd.pcd_loc
    "[reventless-ppx] state field \"%s\" holds the union `%s`, whose arm `%s` carries %s. \
     GraphQL unions admit only object types, and an object type needs at least one field, \
     so every arm of a union used as a state field must declare a named field of its own: \
     `| %s({<field>: <type>})`. An arm that seems to carry nothing usually carries when, or \
     what it was trying."
    field type_name cd.pcd_name.txt carries cd.pcd_name.txt

let check (str : structure) : unit =
  List.iter (fun ((ld : label_declaration), u) ->
    let field = ld.pld_name.txt in
    List.iter (fun (cd : constructor_declaration) ->
      match shape_of cd with
      | Named -> ()
      | shape -> arm_error ~field ~type_name:u.u_type cd shape
    ) u.u_ctors;
    List.iter (fun (attr : attribute) ->
      if List.mem attr.attr_name.txt refused_field_attrs then
        Location.raise_errorf ~loc:attr.attr_loc
          "[reventless-ppx] @%s cannot be used on \"%s\", which holds the union `%s`. \
           Keys, filters, sorts and retirement predicates all compare the field to a \
           scalar, and this field's value is an object whose shape depends on which arm \
           the row is in — the comparison would compile, emit a filter input, and never \
           match. Put the annotation on a scalar field beside the union."
          attr.attr_name.txt field u.u_type
    ) ld.pld_attributes;
    (* The constructor form of `@retired` says "a row in this state is withdrawn",
       and it is read by comparing the stored value to the arm's name. On a payload
       union the stored value is a record, so the predicate never fires and every
       row stays visible — the failure that is invisible until somebody asks where
       the archive went. *)
    List.iter (fun (cd : constructor_declaration) ->
      if Util.has_attr "retired" cd.pcd_attributes then
        Location.raise_errorf ~loc:cd.pcd_loc
          "[reventless-ppx] @retired on arm `%s` of `%s`: retirement is decided by \
           comparing the stored field to a state name, and a union field stores a \
           record rather than a name. Declare the retirement on a scalar lifecycle \
           field beside the union."
          cd.pcd_name.txt u.u_type
    ) u.u_ctors
  ) (state_union_fields str)

(* sury-ppx names the schema of `type t` `schema`, and of every other type
   `<name>Schema`. The shadow has to bind the same name to shadow it. *)
let schema_binding_name type_name =
  if String.equal type_name "t" then "schema" else type_name ^ "Schema"

let named_binding ~loc ~schema_name ~union_name =
  let ident txt = Ast_builder.Default.pexp_ident ~loc { txt; loc } in
  let call =
    Ast_builder.Default.pexp_apply ~loc
      (ident (Ldot (Ldot (Lident "Reventless", "TaggedUnion"), "named")))
      [ (Labelled "name", Ast_builder.Default.estring ~loc union_name);
        (Nolabel, ident (Lident schema_name)) ]
  in
  let binding =
    { pvb_pat = { ppat_desc = Ppat_var { txt = schema_name; loc };
                  ppat_loc = loc;
                  ppat_loc_stack = [];
                  ppat_attributes = [] };
      pvb_expr = call;
      pvb_attributes = [];
      pvb_loc = loc }
  in
  { pstr_desc = Pstr_value (Nonrecursive, [binding]); pstr_loc = loc }

(** Emits the naming shadow immediately after each union the state record holds.

    Immediately after, rather than at the end of the file: [type state]'s own
    schema closes over the binding that is in scope where it is declared, so a
    shadow emitted later would name a union nothing is using. *)
let inject_names ~(prefix : string) (str : structure) : structure =
  let targets =
    state_union_fields str |> List.map (fun (_, u) -> u.u_type)
  in
  if targets = [] then str
  else
    List.concat_map (fun (item : structure_item) ->
      match item.pstr_desc with
      | Pstr_type (_, decls) ->
        let extras =
          List.filter_map (fun (td : type_declaration) ->
            let type_name = td.ptype_name.txt in
            let schema_name = schema_binding_name type_name in
            (* A file that binds the schema name itself has said something about
               this schema already — a semantic mark, a hand-written name — and
               its binding shadows anything emitted here. Leave it to say the
               whole of it. *)
            if List.mem type_name targets && not (Util.has_let_binding schema_name str) then
              Some (named_binding ~loc:td.ptype_loc ~schema_name
                      ~union_name:(prefix ^ String.capitalize_ascii type_name))
            else None
          ) decls
        in
        item :: extras
      | _ -> [item]
    ) str
