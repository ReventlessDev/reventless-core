open Ppxlib

(** Phase 3b.3 — inject type annotations on recognised function bindings in
    implementation files (Behavior, Projection, Automation, Translation).

    The merged Spec + Impl form (pre-Plan-02) disambiguated [consumedEvent] vs
    [event] constructor name collisions by *declaration order* — [evolve]
    appears between the two type declarations, so only [consumedEvent] is in
    scope when the body is type-checked. After the split, both type
    declarations live in the Spec file and are simultaneously in scope inside
    the Impl file via [open Spec]; the order trick stops working.

    Parameter annotations on recognised bindings give the compiler enough
    type-directed disambiguation context to resolve constructor names from
    the parameter type rather than from declaration order. We only annotate
    parameters — not return types or value-level bindings — because:
    - Return-type annotations interact awkwardly with [async] sugar in
      ReScript v12 and aren't needed for the constructor-shadowing fix.
    - Plain values like [initialState] don't suffer from shadowing.

    The injection avoids overriding any annotation the developer already
    supplied: a parameter pattern that is already a [Ppat_constraint] is
    preserved as-is.

    Folder-driven distinction for Translation: Inbound vs. Outbound have
    different [translate] signatures and Outbound additionally has a [collect]
    binding. *)

(* --- Core type builders ----------------------------------------------- *)

let mk_constr ~loc lid args =
  { ptyp_desc = Ptyp_constr ({ txt = lid; loc }, args);
    ptyp_loc = loc;
    ptyp_loc_stack = [];
    ptyp_attributes = [] }

let mk_simple ~loc name = mk_constr ~loc (Lident name) []

let mk_array ~loc inner = mk_constr ~loc (Lident "array") [inner]

let mk_option ~loc inner = mk_constr ~loc (Lident "option") [inner]

let mk_result ~loc ok err = mk_constr ~loc (Lident "result") [ok; err]

let mk_promise ~loc inner = mk_constr ~loc (Lident "promise") [inner]

let mk_tuple ~loc items =
  { ptyp_desc = Ptyp_tuple items;
    ptyp_loc = loc;
    ptyp_loc_stack = [];
    ptyp_attributes = [] }

let mk_string ~loc = mk_simple ~loc "string"

(* [Reventless.Projection.action<string, state>] *)
let mk_projection_action ~loc ~state =
  mk_constr ~loc
    (Ldot (Ldot (Lident "Reventless", "Projection"), "action"))
    [mk_string ~loc; state]

(* [Reventless.StateViewSlice.consumed<inner>] — the projection input envelope
   (event + meta + recordedAt). The [project] param is the envelope, not the
   bare [consumedEvent], so the impl destructures [{event}] out of it. *)
let mk_consumed ~loc inner =
  mk_constr ~loc
    (Ldot (Ldot (Lident "Reventless", "StateViewSlice"), "consumed"))
    [inner]

(* --- Folder detection for Translation inbound/outbound ---------------- *)

let path_contains fname needle =
  let parts = String.split_on_char '/' fname in
  List.exists (fun part -> String.equal part needle) parts

let is_inbound_translation fname =
  path_contains fname "InboundTranslationSlice"
  || path_contains fname "InboundTranslation"

let is_outbound_translation fname =
  path_contains fname "OutboundTranslationSlice"
  || path_contains fname "OutboundTranslation"

(* --- Per-kind annotation table --------------------------------------- *)

type kind_for_injection =
  | KBehavior              (* StateChangeSlice — evolve consumes [consumedEvent] *)
  | KAggregateBehavior     (* Aggregate — evolve consumes [event] *)
  | KProjection
  | KAutomation
  | KInboundTranslation
  | KOutboundTranslation

(* Signature for a binding name in a given kind:
   - [params] : list of parameter types (in declaration order) — empty for
     plain values like [initialState].
   - [ret]   : the return type (or value type for plain values). *)
type signature = {
  params : Ppxlib.core_type list;
  ret    : Ppxlib.core_type;
}

let signature_for ~loc kind name : signature option =
  let s = mk_simple ~loc in
  match kind, name with
  | KBehavior, "initialState" ->
    Some { params = []; ret = s "state" }
  | KBehavior, "evolve" ->
    Some { params = [s "state"; s "consumedEvent"]; ret = s "state" }
  | KBehavior, "decide" ->
    Some { params = [s "state"; s "command"];
           ret = mk_result ~loc (mk_array ~loc (s "event")) (s "error") }

  | KAggregateBehavior, "initialState" ->
    Some { params = []; ret = s "state" }
  | KAggregateBehavior, "evolve" ->
    Some { params = [s "state"; s "event"]; ret = s "state" }
  | KAggregateBehavior, "decide" ->
    Some { params = [s "state"; s "command"];
           ret = mk_result ~loc (mk_array ~loc (s "event")) (s "error") }

  | KProjection, "project" ->
    Some { params = [mk_consumed ~loc (s "consumedEvent")];
           ret = mk_array ~loc (mk_projection_action ~loc ~state:(s "state")) }

  | KAutomation, "collect" ->
    Some { params = [s "consumedEvent"];
           ret = mk_array ~loc (mk_tuple ~loc [mk_string ~loc; s "todoItem"]) }
  | KAutomation, "resolve" ->
    Some { params = [s "consumedEvent"];
           ret = mk_option ~loc (mk_string ~loc) }
  | KAutomation, "process" ->
    Some { params = [mk_string ~loc; s "todoItem"];
           ret = mk_option ~loc (mk_tuple ~loc [mk_string ~loc; s "command"]) }

  | KInboundTranslation, "translate" ->
    Some { params = [s "externalInput"];
           ret = mk_result ~loc
                   (mk_array ~loc (mk_tuple ~loc [mk_string ~loc; s "command"]))
                   (mk_string ~loc) }

  | KOutboundTranslation, "collect" ->
    Some { params = [s "consumedEvent"];
           ret = mk_array ~loc (mk_tuple ~loc [mk_string ~loc; s "outboundItem"]) }
  | KOutboundTranslation, "translate" ->
    Some { params = [mk_string ~loc; s "outboundItem"];
           ret = mk_promise ~loc
                   (mk_result ~loc
                      (mk_option ~loc
                         (mk_tuple ~loc [mk_string ~loc; s "inboundCommand"]))
                      (mk_string ~loc)) }

  | _ -> None

(* --- Annotation injection --------------------------------------------- *)

let pat_var_name (p : pattern) : string option =
  match p.ppat_desc with
  | Ppat_var { txt; _ } -> Some txt
  | _ -> None

(* Annotate a parameter pattern with [ty]. If the pattern is already
   constrained (developer-supplied annotation), preserve it. *)
let annotate_param (pat : pattern) (ty : core_type) : pattern =
  match pat.ppat_desc with
  | Ppat_constraint _ -> pat
  | _ -> { pat with ppat_desc = Ppat_constraint (pat, ty) }

(* Walk a [Pexp_fun] chain, annotating each layer's parameter with the
   corresponding entry from [param_types]. Stops at the first non-[Pexp_fun]
   node (uncurried tuple-arg case, body, etc.). Return-type annotation is
   intentionally skipped — see module docstring. *)
(* ReScript v12 represents uncurried functions as [Function$(inner_fun)] —
   a constructor wrapper around the actual [Pexp_fun] chain. To annotate
   parameters we unwrap the wrapper, walk the inner [Pexp_fun] layers,
   then re-wrap. *)
let annotate_function ~param_types (expr : expression) : expression =
  let rec walk remaining (e : expression) =
    match remaining, e.pexp_desc with
    | [], _ -> e
    | _ :: _, Pexp_construct ({ txt = Lident "Function$"; _ } as lid, Some inner) ->
      let inner' = walk remaining inner in
      { e with pexp_desc = Pexp_construct (lid, Some inner') }
    | ty :: rest, Pexp_fun (label, default, pat, body) ->
      let pat' = annotate_param pat ty in
      let body' = walk rest body in
      { e with pexp_desc = Pexp_fun (label, default, pat', body') }
    | _ :: _, _ -> e  (* fewer Pexp_fun layers than expected — leave alone *)
  in
  walk param_types expr

let annotate_binding ~kind (vb : value_binding) : value_binding =
  match pat_var_name vb.pvb_pat with
  | None -> vb  (* binding pattern isn't a plain name — leave alone *)
  | Some name ->
    (match signature_for ~loc:vb.pvb_loc kind name with
     | None -> vb
     | Some { params; ret = _ } ->
       (match params with
        | [] -> vb  (* plain value — no shadowing risk; skip *)
        | _ ->
          let expr' = annotate_function ~param_types:params vb.pvb_expr in
          { vb with pvb_expr = expr' }))

(* --- Public entry point ---------------------------------------------- *)

let transform_structure ~kind (str : structure) : structure =
  List.map (fun (item : structure_item) ->
    match item.pstr_desc with
    | Pstr_value (rec_flag, bindings) ->
      let bindings' = List.map (annotate_binding ~kind) bindings in
      { item with pstr_desc = Pstr_value (rec_flag, bindings') }
    | _ -> item
  ) str

(* Resolve the injection kind from the impl kind + filename. Aggregate
   Behavior files (outside slice folders) consume [event]; StateChangeSlice
   Behavior files (inside slice folders) consume [consumedEvent]. Translation
   needs inbound/outbound folder discrimination. *)
let kind_from_impl_kind ~fname impl_kind_name =
  match impl_kind_name with
  | "Behavior" ->
    if Util.is_in_slice_folder fname then Some KBehavior
    else Some KAggregateBehavior
  | "Projection" -> Some KProjection
  | "Automation" -> Some KAutomation
  | "Translation" ->
    if is_outbound_translation fname then Some KOutboundTranslation
    else if is_inbound_translation fname then Some KInboundTranslation
    else None  (* no folder hint — skip annotation rather than guess *)
  | _ -> None
