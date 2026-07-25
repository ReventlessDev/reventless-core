open Ppxlib

(* ── @targetState(Orders.Shipped) ──
   Per-variant attribute on aggregate / DCB-slice command variants declaring the
   single status the command's handler writes — the command's *to* state,
   sibling of @allowedStates (the *from* set).

   The payload is a status-type constructor reference, matching @allowedStates'
   authoring shape (`@allowedStates([Orders.Placed]) @targetState(Orders.Shipped)`
   reads consistently). Like @allowedStates, the PPX extracts the leaf
   constructor name as a string for the metadata — it does NOT typecheck the
   reference (the status enum is not in scope at PPX time, and the witness-binding
   approach doesn't survive ReScript's pre-PPX dep analysis); the UI validates the
   value against the view's actual enum at registration. A bare string
   `@targetState("Shipped")` is also accepted for leniency.

   The extracted name lands in the per-variant metadata dict that codegen
   surfaces via `Platform_ComponentDefinitions`, so AutoUI's board drag resolver
   can move a row by a declared transition instead of a name-stem guess.

   Generated metadata binding (mirrors AllowedStatesAnnotation.gen_metadata_binding):
     let commandSchema =
       ReventlessInfra.Api.markTargetState(
         commandSchema,
         [| ("ShipOrder", "Shipped") |],
       )
*)

let attr_name = "targetState"

let strip_attr (attrs : attributes) =
  List.filter (fun (attr : attribute) ->
    not (String.equal attr.attr_name.txt attr_name)
  ) attrs

let find_attr (attrs : attributes) =
  List.find_opt (fun (attr : attribute) ->
    String.equal attr.attr_name.txt attr_name
  ) attrs

(* Extract the leaf constructor name from a longident.
   Lident "Shipped"            → "Shipped"
   Ldot(Lident "Orders", "Shipped") → "Shipped" *)
let leaf_of_lident (lid : Longident.t) : string =
  match lid with
  | Lident name -> name
  | Ldot (_, name) -> name
  | Lapply _ -> failwith "@targetState: functor application is not a valid constructor reference"

(* Parse the attribute payload into its single target-state name. Accepts a
   status-type constructor reference `@targetState(Orders.Shipped)` (preferred,
   consistent with @allowedStates) or a bare string `@targetState("Shipped")`. In
   both cases only the leaf name is kept for the metadata. *)
let parse_payload ~loc (attr : attribute) : string =
  match attr.attr_payload with
  | PStr [{ pstr_desc = Pstr_eval (expr, _); _ }] ->
    (match expr.pexp_desc with
     | Pexp_construct ({ txt = lid; _ }, None) -> leaf_of_lident lid
     | Pexp_ident { txt = lid; _ } -> leaf_of_lident lid
     | Pexp_constant (Pconst_string (s, _, _)) -> s
     | _ ->
       Location.raise_errorf ~loc:expr.pexp_loc
         "@targetState expects a status constructor reference, e.g. @targetState(Orders.Shipped)")
  | _ ->
    Location.raise_errorf ~loc
      "@targetState expects a status constructor reference, e.g. @targetState(Orders.Shipped)"

(* Walk a variant type's constructors, collecting per-constructor target state.
   Returns (variantName, targetState) list. Constructors without @targetState
   contribute nothing. *)
let extract_variant_entries ~loc (td : type_declaration)
  : (string * string) list =
  match td.ptype_kind with
  | Ptype_variant constructors ->
    List.filter_map (fun (cd : constructor_declaration) ->
      match find_attr cd.pcd_attributes with
      | None -> None
      | Some attr -> Some (cd.pcd_name.txt, parse_payload ~loc attr)
    ) constructors
  | _ -> []

(* Emit `let commandSchema = ReventlessInfra.Api.markTargetState(commandSchema, [...])`.
   Mirrors AllowedStatesAnnotation.gen_metadata_binding but with a scalar payload
   per variant. *)
let gen_metadata_binding ~loc ~schema_name entries =
  let str_expr s =
    { pexp_desc = Pexp_constant (Pconst_string (s, loc, None));
      pexp_loc = loc; pexp_loc_stack = []; pexp_attributes = [] } in
  let tuple_expr a b =
    { pexp_desc = Pexp_tuple [a; b];
      pexp_loc = loc; pexp_loc_stack = []; pexp_attributes = [] } in
  let entries_array_items =
    List.map (fun (variant_name, state) ->
      tuple_expr (str_expr variant_name) (str_expr state)
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
        ident (Ldot (Ldot (Lident "ReventlessInfra", "Api"), "markTargetState")),
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

(* Strip @targetState from constructor declarations so sury-ppx doesn't see it
   (it's our own attribute). *)
let strip_from_constructor (cd : constructor_declaration) =
  { cd with pcd_attributes = strip_attr cd.pcd_attributes }

(* Main transform: invoked from ReventlessPpx after AllowedStatesAnnotation so
   the emitted `let commandSchema = markTargetState(commandSchema, …)` chains on
   top of the allowedStates rebinding. Mirrors AllowedStatesAnnotation.transform. *)
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
