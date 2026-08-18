open Ppxlib

(* ── @transition([Orders.Placed] => Orders.Shipped) ──
   ── @transition([Customers.Active]) ──

   Per-variant attribute on aggregate / DCB-slice command variants declaring the
   lifecycle edge the command owns: the states it may run FROM, and — for a
   command that moves the row — the state it lands IN.

   Three forms, one attribute:

     | @transition([Orders.Placed] => Orders.Shipped)   moves the row
       ShipOrder({orderId: string})

     | @transition([Customers.Active])                   guards, moves nothing
       UpdateEmail({customerId: string, email: string})

     | @transition(() => Orders.Placed)                  creates the row
       PlaceOrder({orderId: string})

   Brackets are mandatory on the from-set even for one element, so the forms are
   told apart by the arrow rather than by the shape of the left operand.

   `()` is the EMPTY from-set: a command that brings the row into existence has
   no state to run from, so there is no state that could refuse it. It emits a
   target and no `markAllowedStates` entry, which reads downstream as
   `allowedStates: None, targetState: Some(_)` — unconstrained from, lands
   there. That is a different claim from omitting the attribute, which says
   nothing about where the command lands and draws no edge at all.

   The one-sided form is a POSITIVE CLAIM, not an omission: it says the command
   does not move the row. That is already distinguishable on the wire —
   `allowedStates: Some(_), targetState: None` differs from both being None —
   and consumers are expected to honour it.

   This replaces the @allowedStates / @targetState pair, which said the same
   thing in two attributes that knew nothing about each other and were walked by
   two structurally identical modules over the same structure. Lowering is
   unchanged: the same `markAllowedStates` + `markTargetState` bindings, chained
   in that order, so nothing downstream moves.

     let commandSchema =
       ReventlessInfra.Api.markAllowedStates(commandSchema, [| ("ShipOrder", [|"Placed"|]) |])
     let commandSchema =
       ReventlessInfra.Api.markTargetState(commandSchema, [| ("ShipOrder", "Shipped") |])

   ── On checking the names ──

   The PPX extracts leaf identifiers as strings and cannot do better. The states
   belong to ANOTHER component's lifecycle enum (`Orders.Placed` is declared in
   the view), so the constructor is not in scope here; and a synthetic witness
   binding does not survive ReScript's dependency analysis, which runs pre-PPX —
   that is why the original design's witness was dropped. The attribute is also
   stripped before the typechecker sees it, so a misspelled state is a
   well-formed string all the way down.

   Whether a name is a real member of the lifecycle enum is therefore checked
   where both sides are in hand — at plugin-structure assembly, beside the
   retirement cross-check that validates the same way. Not here.

   Only constructor references are accepted. The removed @targetState took a
   bare string "for leniency"; a stringly-typed state name is precisely the
   unguarded path that form left open, and it would leave the structure-side
   validator a case it cannot check meaningfully. *)

let attr_name = "transition"

(* The pair this replaces. Carried here so a leftover attribute is a build
   error naming its replacement rather than a silent no-op: ignoring one would
   leave the author believing a guard was declared when none was — the same
   stale-metadata failure this annotation exists to end, in a new place. *)
let removed_attr_names = [ "allowedStates"; "targetState" ]

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

(* Raise on a leftover @allowedStates / @targetState. *)
let check_removed_attrs (attrs : attributes) =
  List.iter (fun (attr : attribute) ->
    if List.exists (String.equal attr.attr_name.txt) removed_attr_names then
      Location.raise_errorf ~loc:attr.attr_loc
        "@%s has been removed. Declare the whole edge with @transition instead: \
         @transition([From] => To) for a command that moves the row, \
         @transition([From]) for one that only guards."
        attr.attr_name.txt
  ) attrs

(* Extract the leaf constructor name from a longident.
   Lident "Placed"                 → "Placed"
   Ldot(Lident "Orders", "Placed") → "Placed" *)
let leaf_of_lident ~loc (lid : Longident.t) : string =
  match lid with
  | Lident name -> name
  | Ldot (_, name) -> name
  | Lapply _ ->
    Location.raise_errorf ~loc
      "@transition: a functor application is not a valid state reference"

(* The from-set of the ARROW form arrives as a PATTERN, not an expression:
   ReScript parses `[A, B] => C` as Pexp_fun, whose parameter is
   Ppat_array [Ppat_construct ...]. This is the one shape that is genuinely new
   here — the one-sided form reuses the expression walk below unchanged. *)
let states_of_pattern (pat : pattern) : (string * location) list =
  let one (p : pattern) =
    match p.ppat_desc with
    | Ppat_construct ({ txt = lid; loc = lid_loc }, None) ->
      (leaf_of_lident ~loc:lid_loc lid, lid_loc)
    | Ppat_var { txt = name; loc = var_loc } ->
      (* A lowercase identifier parses as a binder, not a constructor. Reject it
         with the reason rather than silently treating it as a state name. *)
      Location.raise_errorf ~loc:var_loc
        "@transition: \"%s\" is not a state reference. States are constructors \
         of the linked view's lifecycle enum, e.g. Orders.Placed."
        name
    | _ ->
      Location.raise_errorf ~loc:p.ppat_loc
        "@transition: the from-set must be a list of state constructors, \
         e.g. @transition([Orders.Placed, Orders.Shipped] => Orders.Delivered)"
  in
  match pat.ppat_desc with
  (* The creating form's empty from-set. Spelled `()` rather than `[]` because
     it is not a list that happens to be empty — it is the absence of a
     from-state, and the two want telling apart at the authoring site. *)
  | Ppat_construct ({ txt = Lident "()"; _ }, None) -> []
  | Ppat_array [] ->
    Location.raise_errorf ~loc:pat.ppat_loc
      "@transition: an empty from-set is written `()` — \
       @transition(() => Orders.Placed) for a command that creates the row."
  | Ppat_array items -> List.map one items
  | Ppat_construct ({ txt = Lident "::"; _ }, _) | Ppat_construct ({ txt = Lident "[]"; _ }, _) ->
    (* OCaml list syntax, for parity with the expression walk. *)
    let rec walk (p : pattern) =
      match p.ppat_desc with
      | Ppat_construct ({ txt = Lident "::"; _ },
                        Some (_, { ppat_desc = Ppat_tuple [hd; tl]; _ })) ->
        one hd :: walk tl
      | Ppat_construct ({ txt = Lident "[]"; _ }, None) -> []
      | _ -> [ one p ]
    in
    walk pat
  | _ ->
    Location.raise_errorf ~loc:pat.ppat_loc
      "@transition: the from-set must be bracketed, even for one state — \
       @transition([Orders.Placed] => Orders.Shipped)"

(* The one-sided form's from-set, and the arrow form's target, are ordinary
   expressions. Kept close to the walk the removed @allowedStates used, so the
   accepted authoring shapes do not quietly change with the rename. *)
(* A single state reference — the arrow's target. Kept separate from the list
   walk below: a target is one constructor, not a one-element list, and running
   it through the list walk reports a "must be bracketed" error on a target that
   must not be bracketed. *)
let state_of_expression (e : expression) : string * location =
  match e.pexp_desc with
  | Pexp_construct ({ txt = lid; loc = lid_loc }, None) ->
    (leaf_of_lident ~loc:lid_loc lid, lid_loc)
  | Pexp_ident { txt = lid; loc = lid_loc } ->
    (leaf_of_lident ~loc:lid_loc lid, lid_loc)
  | Pexp_constant (Pconst_string (_, str_loc, _)) ->
    Location.raise_errorf ~loc:str_loc
      "@transition: a state must be a constructor reference, not a string. \
       A string state name is never checked against the lifecycle enum."
  | Pexp_array _ ->
    Location.raise_errorf ~loc:e.pexp_loc
      "@transition: a command lands in exactly one state, so the target is not \
       bracketed — @transition(([Orders.Placed]) => Orders.Shipped)"
  | _ ->
    Location.raise_errorf ~loc:e.pexp_loc
      "@transition: the target must be a state constructor, e.g. Orders.Shipped"

let states_of_expression (expr : expression) : (string * location) list =
  let one (e : expression) =
    match e.pexp_desc with
    | Pexp_construct ({ txt = lid; loc = lid_loc }, None) ->
      (leaf_of_lident ~loc:lid_loc lid, lid_loc)
    | Pexp_ident { txt = lid; loc = lid_loc } ->
      (leaf_of_lident ~loc:lid_loc lid, lid_loc)
    | Pexp_constant (Pconst_string (_, str_loc, _)) ->
      Location.raise_errorf ~loc:str_loc
        "@transition: a state must be a constructor reference, not a string. \
         A string state name is never checked against the lifecycle enum."
    | _ ->
      Location.raise_errorf ~loc:e.pexp_loc
        "@transition: states must be constructor references, \
         e.g. Orders.Placed"
  in
  let rec walk (e : expression) =
    match e.pexp_desc with
    (* ReScript `[a, b, c]` parses to Pexp_array *)
    | Pexp_array items -> List.map one items
    (* OCaml list syntax `[a; b; c]` *)
    | Pexp_construct ({ txt = Lident "::"; _ },
                      Some { pexp_desc = Pexp_tuple [hd; tl]; _ }) ->
      one hd :: walk tl
    | Pexp_construct ({ txt = Lident "[]"; _ }, None) -> []
    | _ ->
      Location.raise_errorf ~loc:e.pexp_loc
        "@transition: the from-set must be bracketed, even for one state — \
         @transition([Customers.Active])"
  in
  walk expr

(* One variant's declared edge. `target = None` is the guard-only form: a claim
   that the command moves nothing, not an unfinished declaration. *)
type edge = {
  from_states : (string * location) list;
  target : string option;
}

let parse_payload ~loc (attr : attribute) : edge =
  let payload_expr =
    match attr.attr_payload with
    | PStr [{ pstr_desc = Pstr_eval (expr, _); _ }] -> expr
    | _ ->
      Location.raise_errorf ~loc
        "@transition expects a from-set, optionally with a target: \
         @transition([Orders.Placed] => Orders.Shipped) or \
         @transition([Customers.Active])"
  in
  (* ReScript wraps an arrow in its uncurried marker before the PPX sees it:
     `([A]) => B` arrives as `Function$(fun [|A|] -> B)[@res.arity 1]`, not as a
     bare Pexp_fun. Unwrap it, or the arrow form falls through to the one-sided
     branch and reports a bracket error on a payload that has brackets.

     The marker is a CONSTRUCTOR application, not a function application — the
     arrow arrives as `Pexp_construct (Function$, Some (Pexp_fun …))` carrying a
     `[@res.arity]` attribute. Worth naming precisely, because the list form is
     also a `Pexp_construct` (`::`) and unwrapping constructors indiscriminately
     would eat it. *)
  let rec unwrap (e : expression) : expression =
    match e.pexp_desc with
    | Pexp_construct ({ txt = Lident "Function$"; _ }, Some inner) -> unwrap inner
    | _ -> e
  in
  let payload_expr = unwrap payload_expr in
  match payload_expr.pexp_desc with
  (* Arrow form. ReScript parses `=>` as a function, so the from-set is the
     parameter pattern and the target is the body. *)
  | Pexp_fun (_, _, from_pat, target_expr) ->
    (* An empty from-set is legal here and only here: with a target it is the
       creating edge. Without one it would be the guard-only form claiming a
       command is legal in no state, which is what the branch below refuses. *)
    let from_states = states_of_pattern from_pat in
    let (target, _) = state_of_expression target_expr in
    { from_states; target = Some target }
  (* One-sided form. *)
  | _ ->
    let from_states = states_of_expression payload_expr in
    if from_states = [] then
      Location.raise_errorf ~loc:payload_expr.pexp_loc
        "@transition: the from-set is empty. A command that is legal \
         everywhere declares no @transition at all."
    else { from_states; target = None }

(* Walk a variant type's constructors, collecting the declared edge per
   constructor. Constructors without @transition contribute nothing — but a
   constructor carrying a removed attribute stops the build here. *)
let extract_variant_entries ~loc (td : type_declaration) : (string * edge) list =
  match td.ptype_kind with
  | Ptype_variant constructors ->
    List.filter_map (fun (cd : constructor_declaration) ->
      check_removed_attrs cd.pcd_attributes;
      match find_attr cd.pcd_attributes with
      | None -> None
      | Some attr -> Some (cd.pcd_name.txt, parse_payload ~loc attr)
    ) constructors
  | _ -> []

(* ── Emission ──
   Two bindings, same shapes the removed pair emitted, chained so the target
   rebinding sits on top of the allowed-states one. *)

let str_expr ~loc s =
  { pexp_desc = Pexp_constant (Pconst_string (s, loc, None));
    pexp_loc = loc; pexp_loc_stack = []; pexp_attributes = [] }

let str_array ~loc names =
  { pexp_desc = Pexp_array (List.map (str_expr ~loc) names);
    pexp_loc = loc; pexp_loc_stack = []; pexp_attributes = [] }

let tuple_expr ~loc a b =
  { pexp_desc = Pexp_tuple [a; b];
    pexp_loc = loc; pexp_loc_stack = []; pexp_attributes = [] }

let ident ~loc lid =
  { pexp_desc = Pexp_ident { txt = lid; loc };
    pexp_loc = loc; pexp_loc_stack = []; pexp_attributes = [] }

let rebind ~loc ~schema_name ~fn_name entries_array =
  let set_call =
    { pexp_desc = Pexp_apply (
        ident ~loc (Ldot (Ldot (Lident "ReventlessInfra", "Api"), fn_name)),
        [ (Nolabel, ident ~loc (Lident schema_name));
          (Nolabel, entries_array) ]);
      pexp_loc = loc; pexp_loc_stack = []; pexp_attributes = [] } in
  { pstr_desc = Pstr_value (Nonrecursive, [
      { pvb_pat = { ppat_desc = Ppat_var { txt = schema_name; loc };
                    ppat_loc = loc; ppat_loc_stack = []; ppat_attributes = [] };
        pvb_expr = set_call;
        pvb_attributes = [];
        pvb_loc = loc } ]);
    pstr_loc = loc }

(* Only the variants that constrain where they run FROM. A creating command must
   NOT appear here: an entry with an empty state array would publish
   `allowedStates: Some([])` — legal in no state — and every consumer that
   filters on it would then hide the one command that brings a row into being. *)
let gen_allowed_binding ~loc ~schema_name entries =
  let items =
    List.filter_map (fun (variant_name, edge) ->
      match edge.from_states with
      | [] -> None
      | from_states ->
        Some (tuple_expr ~loc
          (str_expr ~loc variant_name)
          (str_array ~loc (List.map fst from_states)))
    ) entries
  in
  if items = [] then None
  else
    Some (rebind ~loc ~schema_name ~fn_name:"markAllowedStates"
      { pexp_desc = Pexp_array items;
        pexp_loc = loc; pexp_loc_stack = []; pexp_attributes = [] })

(* Only the variants that declare a target. A guard-only command must NOT appear
   here — its absence is what tells a consumer the command moves nothing. *)
let gen_target_binding ~loc ~schema_name entries =
  let items =
    List.filter_map (fun (variant_name, edge) ->
      match edge.target with
      | None -> None
      | Some state ->
        Some (tuple_expr ~loc (str_expr ~loc variant_name) (str_expr ~loc state))
    ) entries
  in
  if items = [] then None
  else
    Some (rebind ~loc ~schema_name ~fn_name:"markTargetState"
      { pexp_desc = Pexp_array items;
        pexp_loc = loc; pexp_loc_stack = []; pexp_attributes = [] })

(* Strip @transition from constructor declarations so sury-ppx doesn't see it
   (it's our own attribute). *)
let strip_from_constructor (cd : constructor_declaration) =
  { cd with pcd_attributes = strip_attr cd.pcd_attributes }

(* Main transform: invoked from ReventlessPpx on every spec body. One traversal
   emitting both bindings, where the removed pair took two. *)
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
                  @ (match gen_allowed_binding ~loc ~schema_name entries with
                     | Some b -> [b]
                     | None -> [])
                  @ (match gen_target_binding ~loc ~schema_name entries with
                     | Some b -> [b]
                     | None -> []);
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
