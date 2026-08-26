open Ppxlib

(* ── The port's translation table, read off the mapping's own arms ──
   Which internal event each `PublishEvent` publishes, and which commands each
   published event routes to. Transcribed from the switch rather than declared,
   so the names cannot be misspelled — they are the constructors the compiler
   already checked.

   A shape it cannot follow is a compile error naming the arm, never a partial
   table: "no edge" and "did not look" must not read alike. The author then
   writes the binding by hand and the derivation steps aside. *)

exception Unfollowable of Location.t * string

let rec last_of : Longident.t -> string = function
  | Lident s -> s
  | Ldot (_, s) -> s
  | Lapply (_, b) -> last_of b

(* Down to what a function actually returns: past the parameters (ReScript v12
   wraps every lambda as [Function$(inner)] — see SidecarEmit), past a type
   annotation, and past any preamble the body opens with. *)
let rec strip_funs (e : expression) : expression =
  match e.pexp_desc with
  | Pexp_construct ({ txt = Lident "Function$"; _ }, Some inner) -> strip_funs inner
  | Pexp_fun (_, _, _, body) -> strip_funs body
  | Pexp_constraint (inner, _) -> strip_funs inner
  | Pexp_let (_, _, body) -> strip_funs body
  | Pexp_sequence (_, body) -> strip_funs body
  | Pexp_open (_, body) -> strip_funs body
  | _ -> e

let rec ctor_of (e : expression) : string option =
  match e.pexp_desc with
  | Pexp_construct ({ txt; _ }, _) -> Some (last_of txt)
  | Pexp_constraint (inner, _) -> ctor_of inner
  | _ -> None

(* The constructors a case's pattern names. [None] for a wildcard — a source the
   pattern does not name. *)
let rec pattern_ctors (p : pattern) : string list option =
  match p.ppat_desc with
  | Ppat_construct ({ txt; _ }, _) -> Some [ last_of txt ]
  | Ppat_or (a, b) -> (
    match (pattern_ctors a, pattern_ctors b) with
    | Some x, Some y -> Some (x @ y)
    | _ -> None)
  | Ppat_alias (inner, _) | Ppat_constraint (inner, _) | Ppat_open (_, inner) ->
    pattern_ctors inner
  | _ -> None

(* Which action constructors carry a routed message, and where its constructor
   sits in the payload. Everything else in the union either carries no name this
   can read (a promise, an opaque forward) or routes nothing (a directive). *)
type side = Published | Handled

let target_of_action ~(side : side) ~loc (name : string) (arg : expression option) :
    string option =
  let nth_of_tuple n =
    match arg with
    | Some { pexp_desc = Pexp_tuple parts; _ } when List.length parts > n ->
      ctor_of (List.nth parts n)
    | _ -> None
  in
  let single () = match arg with Some e -> ctor_of e | None -> None in
  let follow got what =
    match got with
    | Some n -> Some n
    | None ->
      raise (Unfollowable (loc, Printf.sprintf "%s is not a constructor here" what))
  in
  match (side, name) with
  | Published, "PublishEvent" -> follow (nth_of_tuple 1) "the published event"
  | Handled, ("PublishAggregateCommand" | "PublishExtensionPointCommand") ->
    follow (nth_of_tuple 1) "the published command"
  | Handled, "PublishStateChangeSliceCommand" -> follow (single ()) "the published command"
  (* A directive is a local side effect, not a routed message. *)
  | _, "HandleDirective" -> None
  | _, ("PublishEventAsync" | "PublishAggregateCommandAsync" | "PublishAggregateCommandsAsync"
       | "PublishStateChangeSliceCommandAsync" | "PublishStateChangeSliceCommandsAsync") ->
    raise (Unfollowable (loc, Printf.sprintf "`%s` hides what it publishes behind a promise" name))
  | _, "ForwardCommand" ->
    raise (Unfollowable (loc, "`ForwardCommand` carries the command as opaque JSON"))
  | _, other ->
    raise (Unfollowable (loc, Printf.sprintf "`%s` is not an action this can read" other))

(* One element of the returned action array. *)
let element ~side ~(emit : string -> unit) (e : expression) : unit =
  let rec go (e : expression) =
    match e.pexp_desc with
    | Pexp_constraint (inner, _) -> go inner
    | Pexp_construct ({ txt; _ }, arg) -> (
      match target_of_action ~side ~loc:e.pexp_loc (last_of txt) arg with
      | Some n -> emit n
      | None -> ())
    | _ -> raise (Unfollowable (e.pexp_loc, "the arm returns something other than actions"))
  in
  go e

let is_lambda (e : expression) : bool =
  match e.pexp_desc with
  | Pexp_construct ({ txt = Lident "Function$"; _ }, Some _) | Pexp_fun _ -> true
  | _ -> false

let is_call (e : expression) : bool =
  match e.pexp_desc with Pexp_apply _ -> true | _ -> false

let is_literal (e : expression) : bool =
  match e.pexp_desc with
  | Pexp_array _ -> true
  | Pexp_construct ({ txt = Lident ("[]" | "::"); _ }, _) -> true
  | _ -> false

let is_action_construct (e : expression) : bool =
  match e.pexp_desc with
  | Pexp_construct ({ txt; _ }, _) -> (
    match last_of txt with "[]" | "::" | "Some" | "None" -> false | _ -> true)
  | _ -> false

let bindings_of (vbs : value_binding list) : (string * expression) list =
  List.filter_map
    (fun (vb : value_binding) ->
      match vb.pvb_pat.ppat_desc with
      | Ppat_var { txt; _ } | Ppat_constraint ({ ppat_desc = Ppat_var { txt; _ }; _ }, _) ->
        Some (txt, vb.pvb_expr)
      | _ -> None)
    vbs

let ident_name (e : expression) : string option =
  match e.pexp_desc with Pexp_ident { txt = Lident n; _ } -> Some n | _ -> None

(* What a name bound in the arm holds. An arm that builds part of its result
   separately and merges it in — `Array.concat([…], extra)` — passes that name
   where the walk below expects data, which is the one way an edge could be lost
   in silence. [Unknown] is a call whose result cannot be told from data: refused
   rather than guessed at, so it surfaces as an unreadable arm. *)
type bound = Actions | Data | Unknown

let rec classify (env : (string * expression) list) (e : expression) : bound =
  let branches bs =
    let cs = List.map (classify env) bs in
    if List.mem Unknown cs then Unknown
    else if List.mem Actions cs then Actions
    else Data
  in
  match e.pexp_desc with
  | Pexp_constraint (inner, _) | Pexp_open (_, inner) -> classify env inner
  | Pexp_let (_, vbs, cont) -> classify (bindings_of vbs @ env) cont
  | Pexp_sequence (_, cont) -> classify env cont
  (* An empty result names nothing either way. *)
  | Pexp_array [] | Pexp_construct ({ txt = Lident "[]"; _ }, None) -> Data
  | Pexp_array elems -> if List.exists is_action_construct elems then Actions else Data
  | Pexp_construct ({ txt = Lident "::"; _ }, Some { pexp_desc = Pexp_tuple [ hd; tl ]; _ }) ->
    if is_action_construct hd then Actions else classify env tl
  | Pexp_ifthenelse (_, a, b) -> branches (a :: (match b with Some b -> [ b ] | None -> []))
  | Pexp_match (_, cases) | Pexp_try (_, cases) ->
    branches (List.map (fun (c : case) -> c.pc_rhs) cases)
  | Pexp_construct _ when is_action_construct e -> Actions
  | Pexp_apply _ -> Unknown
  | Pexp_ident { txt = Lident n; _ } -> (
    match List.assoc_opt n env with
    | Some b -> classify (List.remove_assoc n env) b
    | None -> Data)
  | _ -> Data

(* Walked in tail position: only what reaches the returned array is read. [env]
   carries the arm's own `let` bindings, so a name standing for actions is
   followed rather than passed over. *)
let rec walk_body ~side ~emit ~env (e : expression) : unit =
  let recur = walk_body ~side ~emit ~env in
  match e.pexp_desc with
  | Pexp_constraint (inner, _) -> recur inner
  | Pexp_let (_, vbs, cont) -> walk_body ~side ~emit ~env:(bindings_of vbs @ env) cont
  | Pexp_sequence (_, cont) -> recur cont
  | Pexp_open (_, cont) -> recur cont
  | Pexp_array elems -> List.iter (element ~side ~emit) elems
  | Pexp_construct ({ txt = Lident "[]"; _ }, None) -> ()
  | Pexp_construct ({ txt = Lident "::"; _ }, Some { pexp_desc = Pexp_tuple [ hd; tl ]; _ }) ->
    element ~side ~emit hd;
    recur tl
  | Pexp_ifthenelse (_, a, b) ->
    recur a;
    (match b with Some b -> recur b | None -> ())
  | Pexp_match (_, cases) | Pexp_try (_, cases) ->
    List.iter (fun (c : case) -> recur c.pc_rhs) cases
  (* A lone action — the body of `ids->Array.map(id => PublishEvent(...))`. *)
  | Pexp_construct _ when is_action_construct e -> element ~side ~emit e
  (* A name the arm bound above. Followed under the env it was bound in minus
     itself, so a shadowing rebind cannot loop. *)
  | Pexp_ident { txt = Lident n; _ } -> (
    match List.assoc_opt n env with
    | Some bound -> walk_body ~side ~emit ~env:(List.remove_assoc n env) bound
    | None ->
      raise
        (Unfollowable (e.pexp_loc, Printf.sprintf "`%s` is not bound to actions this can read" n))
    )
  (* A call: the actions can only be in a lambda it runs, in a nested call (the
     `->` pipe puts the real one there), in a literal it is given, or behind a
     name the arm bound to actions. Everything else is data. A call carrying none
     of those is opaque and is refused. *)
  | Pexp_apply (_, args) ->
    let carries a =
      is_lambda a || is_call a || is_literal a
      ||
      match ident_name a with
      | Some n when List.mem_assoc n env -> classify env a <> Data
      | _ -> false
    in
    let carriers = List.filter (fun (_, a) -> carries a) args in
    if List.length carriers = 0 then
      raise
        (Unfollowable
           (e.pexp_loc, "the arm calls out to something whose actions cannot be read here"))
    else
      List.iter
        (fun (_, a) -> if is_lambda a then recur (strip_funs a) else recur a)
        carriers
  | _ -> raise (Unfollowable (e.pexp_loc, "the arm returns something other than actions"))

(* The (source, target) edges the arms declare, in source order. *)
let edges_of_switch ~side (expr : expression) : (string * string) list =
  match (strip_funs expr).pexp_desc with
  | Pexp_match (_, cases) ->
    List.concat_map
      (fun (c : case) ->
        let targets = ref [] in
        walk_body ~side ~emit:(fun n -> targets := !targets @ [ n ]) ~env:[] c.pc_rhs;
        match (pattern_ctors c.pc_lhs, !targets) with
        | _, [] -> []
        | Some sources, targets ->
          List.concat_map (fun s -> List.map (fun t -> (s, t)) targets) sources
        | None, _ ->
          raise
            (Unfollowable
               ( c.pc_lhs.ppat_loc,
                 "a wildcard arm publishes something, so the events it covers have no names" )))
      cases
  | _ ->
    raise
      (Unfollowable (expr.pexp_loc, "the mapping is not a switch over the incoming message"))

(* Grouped one way for each side: a published event names the internal events
   producing it (many-to-one is the case a port exists for), a handled event
   names the commands it routes to. *)
let group ~(key : string * string -> string) ~(value : string * string -> string)
    (edges : (string * string) list) : (string * string list) list =
  List.fold_left
    (fun acc edge ->
      let k = key edge and v = value edge in
      match List.assoc_opt k acc with
      | Some vs -> if List.mem v vs then acc else List.map (fun (k', vs') -> if String.equal k' k then (k', vs' @ [ v ]) else (k', vs')) acc
      | None -> acc @ [ (k, [ v ]) ])
    [] edges

(* ── Injection ──────────────────────────────────────────────────────────── *)

let record ~loc ~modul ~target_field (target : string) (sources : string list) : expression =
  let open Ast_builder.Default in
  let field name = { txt = Ldot (Ldot (Lident "ReventlessInfra", modul), name); loc } in
  pexp_record ~loc
    [ (field "name", estring ~loc target);
      (field target_field, pexp_array ~loc (List.map (estring ~loc) sources)) ]
    None

let binding ~loc ~modul ~type_name ~value_name ~target_field rows : structure_item =
  let open Ast_builder.Default in
  let arr =
    pexp_array ~loc (List.map (fun (t, ss) -> record ~loc ~modul ~target_field t ss) rows)
  in
  let typ =
    ptyp_constr ~loc { txt = Lident "array"; loc }
      [ ptyp_constr ~loc
          { txt = Ldot (Ldot (Lident "ReventlessInfra", modul), type_name); loc }
          [] ]
  in
  pstr_value ~loc Nonrecursive
    [ value_binding ~loc
        ~pat:(ppat_constraint ~loc (ppat_var ~loc { txt = value_name; loc }) typ)
        ~expr:arr ]

let value_of_binding (name : string) (body : structure) : expression option =
  List.fold_left
    (fun acc (item : structure_item) ->
      match item.pstr_desc with
      | Pstr_value (_, bindings) ->
        List.fold_left
          (fun acc (vb : value_binding) ->
            match vb.pvb_pat.ppat_desc with
            | Ppat_var { txt; _ } when String.equal txt name -> Some vb.pvb_expr
            | Ppat_constraint ({ ppat_desc = Ppat_var { txt; _ }; _ }, _)
              when String.equal txt name ->
              Some vb.pvb_expr
            | _ -> acc)
          acc bindings
      | _ -> acc)
    None body

let report ~what (exn_loc, why) =
  Location.raise_errorf ~loc:exn_loc
    "reventless: cannot read %s from this arm — %s. Write the table by hand (`let %s = \
     [...]`) and this derivation steps aside."
    what why what

let edges ~side ~what expr =
  try edges_of_switch ~side expr with Unfollowable (l, why) -> report ~what (l, why)

(* `let publishedEvents` on an ExtensionPoint mapping file, read off
   `mapOutgoingEvent`. Absent or `None` publishes nothing. Keyed by published
   event, so the many-to-one case a port exists for reads naturally. *)
let derive_published ~loc (body : structure) : structure_item option =
  if Util.has_let_binding "publishedEvents" body then None
  else
    let what = "publishedEvents" in
    let rows =
      match value_of_binding "mapOutgoingEvent" body with
      | None -> []
      | Some { pexp_desc = Pexp_construct ({ txt = Lident "None"; _ }, None); _ } -> []
      | Some { pexp_desc = Pexp_construct ({ txt = Lident "Some"; _ }, Some inner); _ } ->
        edges ~side:Published ~what inner
      | Some other -> edges ~side:Published ~what other
    in
    Some
      (binding ~loc ~modul:"ExtensionPointMapping" ~type_name:"publishedEvent"
         ~value_name:what ~target_field:"fromEventTypes"
         (group ~key:snd ~value:fst rows))

(* `let handledEvents` inside `module Mapping` of an extension file, read off
   `mapIncomingEvent`. Keyed by the published event it handles. *)
let derive_handled ~loc (inner : structure) : structure_item option =
  if Util.has_let_binding "handledEvents" inner then None
  else
    let what = "handledEvents" in
    let rows =
      match value_of_binding "mapIncomingEvent" inner with
      | None -> []
      | Some e -> edges ~side:Handled ~what e
    in
    Some
      (binding ~loc ~modul:"ExtensionMapping" ~type_name:"handledEvent" ~value_name:what
         ~target_field:"toCommandTypes" (group ~key:fst ~value:snd rows))

(* The framework's own ports are inner modules inside a functor — a platform
   mapping is parameterised by runtime ops it can only receive at build time —
   and test fixtures declare theirs inline. Walk into any module shaped like a
   mapping so those tables are derived too, whatever the file is called.

   Which side a module is on is read off its inbound function, the way the two
   module types differ: an extension maps incoming EVENTS, an extension point
   maps incoming COMMANDS. Both bind `mapOutgoingEvent`, and they mean different
   things by it. *)
let rec walk_inline_mappings (str : structure) : structure =
  List.map
    (fun (item : structure_item) ->
      match item.pstr_desc with
      | Pstr_module mb ->
        { item with pstr_desc = Pstr_module { mb with pmb_expr = walk_module_expr mb.pmb_expr } }
      | _ -> item)
    str

and walk_module_expr (me : module_expr) : module_expr =
  match me.pmod_desc with
  | Pmod_structure body ->
    let body = walk_inline_mappings body in
    let loc = me.pmod_loc in
    let looks_like_mapping =
      Util.has_module_binding "ExtensionPoint" body && Util.has_module_binding "Delegate" body
    in
    let body =
      if not looks_like_mapping then body
      else if Util.has_let_binding "mapIncomingEvent" body then
        match derive_handled ~loc body with Some t -> body @ [ t ] | None -> body
      else if Util.has_let_binding "mapOutgoingEvent" body then
        match derive_published ~loc body with Some t -> body @ [ t ] | None -> body
      else body
    in
    { me with pmod_desc = Pmod_structure body }
  | Pmod_functor (p, inner) -> { me with pmod_desc = Pmod_functor (p, walk_module_expr inner) }
  | Pmod_constraint (inner, mt) ->
    { me with pmod_desc = Pmod_constraint (walk_module_expr inner, mt) }
  (* `Make({ … })` — the mapping handed straight to a functor, with no name of
     its own. The table hangs inside the anonymous structure. *)
  | Pmod_apply (f, arg) ->
    { me with pmod_desc = Pmod_apply (walk_module_expr f, walk_module_expr arg) }
  | _ -> me
