open Ppxlib

(* ── @allowedStates([Constructor1, Module.Constructor2, ...]) ──
   Per-variant attribute on aggregate / DCB-slice command variants.

   The payload is an EXPRESSION LIST of status-type constructor references.
   The PPX:
     (a) extracts each constructor's leaf identifier as a string for the
         metadata payload that codegen ultimately surfaces via
         `Platform_UIDefinitions`;
     (b) emits a synthetic `let _ = Module.Constructor` witness binding at
         the structure top so the OCaml compiler errors at the original
         site if a constructor is misspelled, renamed, or removed.

   The witness shape works uniformly for both payloadless and payload
   variants: a payloadless constructor (e.g. `Submitted`) is a value;
   a payload constructor (e.g. `Shipped`) is an unapplied function. Both
   are valid right-hand sides of a `let _ = ...` binding, so we never need
   to know the variant's arity.

   Generated metadata binding (mirrors NoApiAnnotation.gen_no_api_variants_metadata_binding):
     let commandSchema =
       ReventlessInfra.Api.markAllowedStates(
         commandSchema,
         [| ("V1", [|"S1"; "S2"|]); ("V2", [|"S3"|]) |],
       )
*)

let attr_name = "allowedStates"

let has_attr (attrs : attributes) =
  List.exists (fun (attr : attribute) ->
    String.equal attr.attr_name.txt attr_name
  ) attrs

let strip_attr (attrs : attributes) =
  List.filter (fun (attr : attribute) ->
    not (String.equal attr.attr_name.txt attr_name)
  ) attrs

let find_attr (attrs : attributes) =
  List.find_opt (fun (attr : attribute) ->
    String.equal attr.attr_name.txt attr_name
  ) attrs

(* Extract leaf constructor name from a longident.
   Lident "Submitted"          → "Submitted"
   Ldot(Lident "Mod", "Shipped") → "Shipped" *)
let leaf_of_lident (lid : Longident.t) : string =
  match lid with
  | Lident name -> name
  | Ldot (_, name) -> name
  | Lapply _ -> failwith "@allowedStates: functor application is not a valid constructor reference"

(* Parse the attribute payload into (longident, location) pairs, one per
   constructor reference in the list. Accepts both array form `[A, B]` and
   list form `[A; B]` because Ppxlib normalises the parsed AST. *)
let parse_payload ~loc (attr : attribute) : (Longident.t * location) list =
  let payload_expr =
    match attr.attr_payload with
    | PStr [{ pstr_desc = Pstr_eval (expr, _); _ }] -> expr
    | _ ->
      Location.raise_errorf ~loc
        "@allowedStates expects a list payload, e.g. @allowedStates([Submitted, Shipped])"
  in
  let rec extract_constructors_from_expr (expr : expression) : (Longident.t * location) list =
    match expr.pexp_desc with
    (* ReScript `[a, b, c]` becomes Pexp_array on parsing *)
    | Pexp_array items ->
      List.map extract_one items
    (* OCaml list syntax `[a; b; c]` becomes nested constructors *)
    | Pexp_construct ({ txt = Lident "::"; _ },
                      Some { pexp_desc = Pexp_tuple [hd; tl]; _ }) ->
      extract_one hd :: extract_constructors_from_expr tl
    | Pexp_construct ({ txt = Lident "[]"; _ }, None) ->
      []
    | _ ->
      Location.raise_errorf ~loc:expr.pexp_loc
        "@allowedStates payload must be a list of constructor references"
  and extract_one (expr : expression) : Longident.t * location =
    match expr.pexp_desc with
    | Pexp_construct ({ txt = lid; loc = lid_loc }, None) ->
      (lid, lid_loc)
    | Pexp_ident { txt = lid; loc = lid_loc } ->
      (lid, lid_loc)
    | _ ->
      Location.raise_errorf ~loc:expr.pexp_loc
        "@allowedStates items must be constructor references (e.g. Submitted or OrdersStatus.Shipped)"
  in
  extract_constructors_from_expr payload_expr

(* Walk a variant type's constructors, collecting per-constructor allowed
   states. Returns (variantName, (allowedStateName * witnessLongident) list) list.
   Constructors without @allowedStates contribute nothing. *)
let extract_variant_entries ~loc (td : type_declaration)
  : (string * (string * Longident.t * location) list) list =
  match td.ptype_kind with
  | Ptype_variant constructors ->
    List.filter_map (fun (cd : constructor_declaration) ->
      match find_attr cd.pcd_attributes with
      | None -> None
      | Some attr ->
        let pairs = parse_payload ~loc attr in
        let entries =
          List.map (fun (lid, l) -> (leaf_of_lident lid, lid, l)) pairs
        in
        Some (cd.pcd_name.txt, entries)
    ) constructors
  | _ -> []

(* Emit `let _ = Module.Constructor` at structure top per unique constructor
   referenced. The compiler resolves and type-checks the constructor here. *)
let gen_witness_bindings ~loc entries =
  let seen = Hashtbl.create 16 in
  List.concat_map (fun (_variant, pairs) ->
    List.filter_map (fun (_name, lid, lid_loc) ->
      let key = Longident.flatten_exn lid |> String.concat "." in
      if Hashtbl.mem seen key then None
      else begin
        Hashtbl.add seen key ();
        let ref_expr =
          { pexp_desc = Pexp_ident { txt = lid; loc = lid_loc };
            pexp_loc = lid_loc; pexp_loc_stack = []; pexp_attributes = [] } in
        let binding =
          { pvb_pat = { ppat_desc = Ppat_any;
                        ppat_loc = loc;
                        ppat_loc_stack = [];
                        ppat_attributes = [] };
            pvb_expr = ref_expr;
            pvb_attributes = [];
            pvb_loc = loc } in
        Some { pstr_desc = Pstr_value (Nonrecursive, [binding]); pstr_loc = loc }
      end
    ) pairs
  ) entries

(* Emit `let commandSchema = ReventlessInfra.Api.markAllowedStates(commandSchema, [...])`.
   Mirrors `gen_no_api_variants_metadata_binding`. *)
let gen_metadata_binding ~loc ~schema_name entries =
  let str_expr s =
    { pexp_desc = Pexp_constant (Pconst_string (s, loc, None));
      pexp_loc = loc; pexp_loc_stack = []; pexp_attributes = [] } in
  let str_array names =
    { pexp_desc = Pexp_array (List.map str_expr names);
      pexp_loc = loc; pexp_loc_stack = []; pexp_attributes = [] } in
  let tuple_expr a b =
    { pexp_desc = Pexp_tuple [a; b];
      pexp_loc = loc; pexp_loc_stack = []; pexp_attributes = [] } in
  let entries_array_items =
    List.map (fun (variant_name, pairs) ->
      let state_names = List.map (fun (n, _, _) -> n) pairs in
      tuple_expr (str_expr variant_name) (str_array state_names)
    ) entries
  in
  let entries_array =
    { pexp_desc = Pexp_array entries_array_items;
      pexp_loc = loc; pexp_loc_stack = []; pexp_attributes = [] } in
  let ident lid =
    { pexp_desc = Pexp_ident { txt = lid; loc };
      pexp_loc = loc; pexp_loc_stack = []; pexp_attributes = [] } in
  let set_call =
    { pexp_desc = Pexp_apply (
        ident (Ldot (Ldot (Lident "ReventlessInfra", "Api"), "markAllowedStates")),
        [ (Nolabel, ident (Lident schema_name));
          (Nolabel, entries_array) ]);
      pexp_loc = loc; pexp_loc_stack = []; pexp_attributes = [] } in
  { pstr_desc = Pstr_value (Nonrecursive, [
      { pvb_pat = { ppat_desc = Ppat_var { txt = schema_name; loc };
                    ppat_loc = loc; ppat_loc_stack = []; ppat_attributes = [] };
        pvb_expr = set_call;
        pvb_attributes = [];
        pvb_loc = loc } ]);
    pstr_loc = loc }

(* Strip @allowedStates from constructor declarations so sury-ppx doesn't
   see it (it's our own attribute). *)
let strip_from_constructor (cd : constructor_declaration) =
  { cd with pcd_attributes = strip_attr cd.pcd_attributes }

(* Main transform: invoked from ReventlessPpx on every spec body so it can
   process command type declarations. Mirrors NoApiAnnotation.transform. *)
let transform ~loc (str : structure) =
  let rec process_structure (str : structure) =
    let new_items = ref [] in
    let appended = ref [] in
    List.iter (fun (item : structure_item) ->
      match item.pstr_desc with
      | Pstr_type (rf, decls) ->
        let new_decls =
          List.map (fun (td : type_declaration) ->
            if not (Util.has_attr "schema" td.ptype_attributes) then td
            else
              let entries = extract_variant_entries ~loc td in
              if entries = [] then td
              else begin
                let schema_name = td.ptype_name.txt ^ "Schema" in
                appended := !appended
                  @ gen_witness_bindings ~loc entries
                  @ [gen_metadata_binding ~loc ~schema_name entries];
                let new_ctors = List.map strip_from_constructor (
                  match td.ptype_kind with
                  | Ptype_variant ctors -> ctors
                  | _ -> []
                ) in
                { td with ptype_kind = Ptype_variant new_ctors }
              end
          ) decls in
        new_items := !new_items @ [{ item with pstr_desc = Pstr_type (rf, new_decls) }]
      | Pstr_module mb ->
        let new_expr = process_module_expr mb.pmb_expr in
        new_items := !new_items @ [{ item with pstr_desc = Pstr_module { mb with pmb_expr = new_expr } }]
      | _ ->
        new_items := !new_items @ [item]
    ) str;
    !new_items @ !appended
  and process_module_expr (me : module_expr) : module_expr =
    match me.pmod_desc with
    | Pmod_structure str ->
      { me with pmod_desc = Pmod_structure (process_structure str) }
    | Pmod_functor (param, body) ->
      { me with pmod_desc = Pmod_functor (param, process_module_expr body) }
    | Pmod_constraint (body, mty) ->
      { me with pmod_desc = Pmod_constraint (process_module_expr body, mty) }
    | _ -> me
  in
  process_structure str
