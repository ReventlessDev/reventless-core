(* Read-consistency auto-injection (StateChangeSlice only).

   File-level [@@reventless.consistency(<case>)] (or an inner-level
   equivalent inside a structurally-detected inline slice spec module)
   overrides the framework default ([EscalateOnRetry]). The PPX
   synthesises:

     let readConsistency = <case>          (* StateChangeSlice spec files *)

   No injection happens if the user already declared the binding. Adds
   [open Reventless.ReadConsistency] to the prefix only when the payload
   uses unqualified constructors (the default is emitted fully qualified,
   so unannotated files need no open).

   Mirrors [VisibilityInjection] but for StateChangeSlice command carriers
   only — [readConsistency] is a field on [StateChangeSlice.Spec], not on
   [Aggregate.Spec] / the translation slices. The structural marker is
   [@schema type consumedEvent] AND [@schema type event] (a slice consumes
   events and produces events); aggregates have [event] but no
   [consumedEvent], inbound translation has neither, outbound translation
   has [consumedEvent] but produces a command, not events. The attribute is
   rejected on any non-StateChangeSlice file. *)

open Ppxlib

type kind =
  | StateChangeCarrier
  | NotEligible

let detect_kind fname =
  if Util.is_in_folder fname "StateChangeSlice"
     || Util.is_in_folder fname "StateChangeSlices"
  then StateChangeCarrier
  else NotEligible

(* Default: Reventless.ReadConsistency.EscalateOnRetry — emitted fully
   qualified so no [open] is needed on unannotated files. *)
let default_expr ~loc =
  Ast_builder.Default.pexp_construct
    ~loc
    { txt = Ldot (Ldot (Lident "Reventless", "ReadConsistency"), "EscalateOnRetry"); loc }
    None

(* @@reventless.consistency(<expr>) extraction ------------------------- *)

let extract_file_value (str : structure) : expression option =
  let rec scan = function
    | [] -> None
    | item :: rest ->
      (match item.pstr_desc with
       | Pstr_attribute attr when String.equal attr.attr_name.txt "reventless.consistency" ->
         (match attr.attr_payload with
          | PStr [{ pstr_desc = Pstr_eval (expr, _); _ }] -> Some expr
          | _ -> None)
       | _ -> scan rest)
  in
  scan str

let strip_file_consistency_attrs (str : structure) : structure =
  List.filter (fun (item : structure_item) ->
    match item.pstr_desc with
    | Pstr_attribute attr -> not (String.equal attr.attr_name.txt "reventless.consistency")
    | _ -> true
  ) str

let has_file_consistency_attr (str : structure) : bool =
  List.exists (fun (item : structure_item) ->
    match item.pstr_desc with
    | Pstr_attribute attr -> String.equal attr.attr_name.txt "reventless.consistency"
    | _ -> false
  ) str

(* Generators ----------------------------------------------------------- *)

(* [open Reventless.ReadConsistency] — added to the prefix so case
   constructors resolve unqualified in the payload of
   [@@reventless.consistency(...)]. *)
let gen_open_consistency ~loc =
  let lid = { txt = Ldot (Lident "Reventless", "ReadConsistency"); loc } in
  { pstr_desc = Pstr_open {
      popen_expr = { pmod_desc = Pmod_ident lid; pmod_loc = loc; pmod_attributes = [] };
      popen_override = Fresh;
      popen_loc = loc;
      popen_attributes = [];
    };
    pstr_loc = loc }

(* let readConsistency = <expr> *)
let gen_read_consistency ~loc value =
  let pat = Ast_builder.Default.ppat_var ~loc { txt = "readConsistency"; loc } in
  Ast_builder.Default.pstr_value ~loc Nonrecursive
    [Ast_builder.Default.value_binding ~loc ~pat ~expr:value]

(* Spec-namespace packages skip injection — same rationale as auth/visibility. *)
let is_spec_namespace_pkg loc =
  match ModuleUrl.find_package_for loc with
  | Some pkg -> ModuleUrl.is_spec_namespace pkg
  | None -> false

(* Structural marker: a StateChangeSlice consumes AND produces events. *)
let body_has_schema_type (type_name : string) (body : structure) : bool =
  List.exists (fun (item : structure_item) ->
    match item.pstr_desc with
    | Pstr_type (_, decls) ->
      List.exists (fun (td : type_declaration) ->
        String.equal td.ptype_name.txt type_name
        && Util.has_attr "schema" td.ptype_attributes
      ) decls
    | _ -> false
  ) body

let body_is_state_change_slice (body : structure) : bool =
  body_has_schema_type "consumedEvent" body
  && body_has_schema_type "event" body

let detect_kind_by_structure (body : structure) : kind =
  if body_is_state_change_slice body then StateChangeCarrier else NotEligible

let inject ~loc fname (body : structure) : structure_item list * structure * structure_item list =
  if is_spec_namespace_pkg loc then ([], body, [])
  else
  let kind = match detect_kind fname with
    | NotEligible -> detect_kind_by_structure body
    | k -> k
  in
  match kind with
  | NotEligible ->
    (* Reject the attribute on a non-StateChangeSlice file with a clear message. *)
    if has_file_consistency_attr body then
      Location.raise_errorf ~loc
        "[reventless-ppx] @@@@reventless.consistency is only supported on StateChangeSlice spec files."
    else
      ([], body, [])
  | StateChangeCarrier ->
    let user_value = extract_file_value body in
    let body = strip_file_consistency_attrs body in
    let needs_open =
      Option.is_some user_value
      && not (Util.has_open_dotted "Reventless" "ReadConsistency" body)
    in
    let prefix = if needs_open then [gen_open_consistency ~loc] else [] in
    let value = match user_value with
      | Some e -> e
      | None -> default_expr ~loc
    in
    let suffix =
      if Util.has_let_binding "readConsistency" body
      then []
      else [gen_read_consistency ~loc value]
    in
    (prefix, body, suffix)

(* Inline-module detection + injection --------------------------------- *)
(* A structurally-detected StateChangeSlice-shaped inline module (test
   fixtures, framework-internal helpers) gets a [let readConsistency]
   field so it satisfies StateChangeSlice.Spec. *)

let inner_module_is_state_change_spec (mb : module_binding) : bool =
  match mb.pmb_expr.pmod_desc with
  | Pmod_structure body -> body_is_state_change_slice body
  | _ -> false

let inject_into_inner_module ~loc (mb : module_binding) : module_binding =
  match mb.pmb_expr.pmod_desc with
  | Pmod_structure body ->
    if Util.has_let_binding "readConsistency" body then mb
    else
      let user_value = extract_file_value body in
      let body = strip_file_consistency_attrs body in
      let needs_open =
        Option.is_some user_value
        && not (Util.has_open_dotted "Reventless" "ReadConsistency" body)
      in
      let prefix = if needs_open then [gen_open_consistency ~loc] else [] in
      let value = match user_value with
        | Some e -> e
        | None -> default_expr ~loc
      in
      let new_body = prefix @ body @ [gen_read_consistency ~loc value] in
      { mb with pmb_expr = { mb.pmb_expr with pmod_desc = Pmod_structure new_body } }
  | _ -> mb

(* Walk a structure and inject readConsistency on any StateChangeSlice-shaped
   inner module. Safe to run unconditionally — files with no inline slice
   specs are a no-op. Skipped in *-spec packages. *)
let walk_inline_specs (str : structure) : structure =
  let in_spec_pkg = match str with
    | item :: _ -> is_spec_namespace_pkg item.pstr_loc
    | [] -> false
  in
  if in_spec_pkg then str
  else
  List.map (fun (item : structure_item) ->
    match item.pstr_desc with
    | Pstr_module mb when inner_module_is_state_change_spec mb ->
      let mb' = inject_into_inner_module ~loc:item.pstr_loc mb in
      { item with pstr_desc = Pstr_module mb' }
    | _ -> item
  ) str
