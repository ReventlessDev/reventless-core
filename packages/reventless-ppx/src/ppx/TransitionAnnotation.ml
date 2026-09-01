open Ppxlib

(* ── The removed command-edge attributes ──

   `@transition`, and the `@allowedStates` / `@targetState` pair before it, each
   declared the lifecycle edge a command owns as an attribute on the constructor.
   All three are gone. A spec declares its edges as a value instead:

     type lifecycleState = Orders.lifecycle

     let commandTransition = (command: command): Reventless.Transition.t<lifecycleState> => {
       open Reventless.Transition
       switch command {
       | ShipOrder(_) => Moves([Orders.Placed], Orders.Shipped)
       | CancelShipment(_) => Unrestricted
       }
     }

   Three things the attribute could not do, and this is why it went rather than
   the two forms coexisting behind a precedence rule:

   - It is EXHAUSTIVE. An attribute is optional and its absence says nothing, so
     a command spliced into a host's union from a trait arrived carrying no edge
     at all — the attribute lowers to a dict on the parent union, and a variant
     spread splices members. The switch must answer for what it spliced.

   - The states are CHECKED. They belong to another component's lifecycle enum,
     so the constructor is not in scope where the attribute was written; and the
     attribute is stripped before the typechecker, which left a misspelling a
     well-formed string all the way down. As constructor references the compiler
     resolves them.

   - Every arm names ONE lifecycle. `'state` is fixed per component, so a
     from-set out of one enum with a target out of another does not compile.

   The switch is host-written rather than generated from the attribute because a
   reference this PPX introduces creates no build edge: ReScript's dependency
   analysis runs before it. That is what makes the reference typed at all.

   Kept as a refusal rather than deleted outright: a silently-ignored attribute
   would leave an author believing a guard was declared when none was — the same
   stale-metadata failure the switch exists to end, in a new place. *)

let removed_attrs =
  [ ("transition",
     "Declare the edge as a value instead: a `commandTransition` switch over the \
      command, returning `Reventless.Transition.t<lifecycleState>` — \
      `Moves([Orders.Placed], Orders.Shipped)` for a command that moves the row, \
      `Guards([Orders.Placed])` for one that only guards, `Creates(Orders.Placed)` \
      for one that brings the row into being, `Unrestricted` for one that declares \
      nothing. The states go in as the linked view's own constructors, so the \
      compiler resolves them.");
    ("allowedStates",
     "Declare the edge as a value instead: the from-set is the array in \
      `Guards([...])` or `Moves([...], target)` in a `commandTransition` switch.");
    ("targetState",
     "Declare the edge as a value instead: the target is the second argument of \
      `Moves([...], target)`, or the argument of `Creates(target)`, in a \
      `commandTransition` switch.") ]

let check_removed_attrs (attrs : attributes) =
  List.iter (fun (attr : attribute) ->
    match List.assoc_opt attr.attr_name.txt removed_attrs with
    | None -> ()
    | Some how ->
      Location.raise_errorf ~loc:attr.attr_loc
        "@%s has been removed. %s" attr.attr_name.txt how
  ) attrs

(* Walk every `@schema` variant's constructors. Nothing is emitted and nothing is
   stripped — a leftover attribute stops the build, and a spec without one is
   returned untouched. *)
let transform ~loc:_ (str : structure) =
  let rec process_structure (str : structure) =
    List.iter (fun (item : structure_item) ->
      match item.pstr_desc with
      | Pstr_type (_, decls) ->
        List.iter (fun (td : type_declaration) ->
          if Util.has_attr "schema" td.ptype_attributes then
            match td.ptype_kind with
            | Ptype_variant constructors ->
              List.iter (fun (cd : constructor_declaration) ->
                check_removed_attrs cd.pcd_attributes
              ) constructors
            | _ -> ()
        ) decls
      | Pstr_module mb -> process_module_expr mb.pmb_expr
      | _ -> ()
    ) str
  and process_module_expr (me : module_expr) =
    match me.pmod_desc with
    | Pmod_structure str -> process_structure str
    | Pmod_functor (_, body) -> process_module_expr body
    | Pmod_constraint (body, _) -> process_module_expr body
    | _ -> ()
  in
  process_structure str;
  str
