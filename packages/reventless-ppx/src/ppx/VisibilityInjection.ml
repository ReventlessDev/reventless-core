(* Visibility auto-injection.

   File-level [@@reventless.visibility(<case>)] (or an inner-level
   equivalent inside a structurally-detected inline read-model spec
   module) overrides the framework default ([Public]). The PPX
   synthesises:

     let visibility = <case>          (* ReadModel, StateViewSlice, StateViewSliceStream *)

   No injection happens if the user already declared the binding. Adds
   [open Reventless.Visibility] to the prefix only when the rule payload
   uses unqualified constructors (the default is emitted fully qualified).

   Mirrors [AuthorizationInjection] but for the [QueryCarrier] kind only.
   The attribute is rejected on [CommandCarrier] / [Other] files because
   visibility is only meaningful where a panel/page would otherwise be
   enumerated in the AutoUI manifest. *)

open Ppxlib

(* Detect QueryCarrier kind — matches AuthorizationInjection.detect_kind
   for the QueryCarrier branch only. CommandCarrier and Other are not
   eligible for visibility injection. *)
type kind =
  | QueryCarrier
  | NotEligible

let detect_kind fname =
  if Util.is_in_readmodel_folder fname
     || Util.is_in_folder fname "StateViewSlice"
     || Util.is_in_folder fname "StateViewSliceStream"
     || Util.is_in_folder fname "StateViewSlices"
     || Util.is_in_folder fname "StateViewSliceStreams"
  then QueryCarrier
  else NotEligible

(* Default: Reventless.Visibility.Public — emitted fully qualified so no
   [open] is needed on unannotated files. *)
let default_expr ~loc =
  Ast_builder.Default.pexp_construct
    ~loc
    { txt = Ldot (Ldot (Lident "Reventless", "Visibility"), "Public"); loc }
    None

(* @@reventless.visibility(<expr>) extraction --------------------------- *)

let extract_file_value (str : structure) : expression option =
  let rec scan = function
    | [] -> None
    | item :: rest ->
      (match item.pstr_desc with
       | Pstr_attribute attr when String.equal attr.attr_name.txt "reventless.visibility" ->
         (match attr.attr_payload with
          | PStr [{ pstr_desc = Pstr_eval (expr, _); _ }] -> Some expr
          | _ -> None)
       | _ -> scan rest)
  in
  scan str

let strip_file_visibility_attrs (str : structure) : structure =
  List.filter (fun (item : structure_item) ->
    match item.pstr_desc with
    | Pstr_attribute attr -> not (String.equal attr.attr_name.txt "reventless.visibility")
    | _ -> true
  ) str

let has_file_visibility_attr (str : structure) : bool =
  List.exists (fun (item : structure_item) ->
    match item.pstr_desc with
    | Pstr_attribute attr -> String.equal attr.attr_name.txt "reventless.visibility"
    | _ -> false
  ) str

(* Generators ----------------------------------------------------------- *)

(* [open Reventless.Visibility] — added to the prefix so case constructors
   resolve unqualified in the payload of [@@reventless.visibility(...)]. *)
let gen_open_visibility ~loc =
  let lid = { txt = Ldot (Lident "Reventless", "Visibility"); loc } in
  { pstr_desc = Pstr_open {
      popen_expr = { pmod_desc = Pmod_ident lid; pmod_loc = loc; pmod_attributes = [] };
      popen_override = Fresh;
      popen_loc = loc;
      popen_attributes = [];
    };
    pstr_loc = loc }

(* let visibility = <expr> *)
let gen_visibility ~loc value =
  let pat = Ast_builder.Default.ppat_var ~loc { txt = "visibility"; loc } in
  Ast_builder.Default.pstr_value ~loc Nonrecursive
    [Ast_builder.Default.value_binding ~loc ~pat ~expr:value]

(* Spec-namespace packages skip injection — same rationale as auth. *)
let is_spec_namespace_pkg loc =
  match ModuleUrl.find_package_for loc with
  | Some pkg -> ModuleUrl.is_spec_namespace pkg
  | None -> false

(* Structural fallback mirrors AuthorizationInjection.detect_kind_by_structure.
   A file with [@schema type command] is a command carrier (Aggregate / Slice)
   and is never visibility-eligible, even if it also declares [@schema type state]
   (e.g. an aggregate with internal state). *)
let detect_kind_by_structure (body : structure) : kind =
  let has_schema_type name =
    List.exists (fun (item : structure_item) ->
      match item.pstr_desc with
      | Pstr_type (_, decls) ->
        List.exists (fun (td : type_declaration) ->
          String.equal td.ptype_name.txt name
          && Util.has_attr "schema" td.ptype_attributes
        ) decls
      | _ -> false
    ) body
  in
  if has_schema_type "command" then NotEligible
  else if has_schema_type "state" then QueryCarrier
  else NotEligible

let inject ~loc fname (body : structure) : structure_item list * structure * structure_item list =
  if is_spec_namespace_pkg loc then ([], body, [])
  else
  let kind = match detect_kind fname with
    | NotEligible -> detect_kind_by_structure body
    | k -> k
  in
  match kind with
  | NotEligible ->
    (* Reject the attribute on a non-query-carrier file with a clear message. *)
    if has_file_visibility_attr body then
      Location.raise_errorf ~loc
        "[reventless-ppx] @@@@reventless.visibility is only supported on ReadModel and StateViewSlice spec files."
    else
      ([], body, [])
  | QueryCarrier ->
    let user_value = extract_file_value body in
    let body = strip_file_visibility_attrs body in
    let needs_open =
      Option.is_some user_value
      && not (Util.has_open_dotted "Reventless" "Visibility" body)
    in
    let prefix = if needs_open then [gen_open_visibility ~loc] else [] in
    let value = match user_value with
      | Some e -> e
      | None -> default_expr ~loc
    in
    let suffix =
      if Util.has_let_binding "visibility" body
      then []
      else [gen_visibility ~loc value]
    in
    (prefix, body, suffix)

(* Inline-module detection + injection --------------------------------- *)
(* Mirrors AuthorizationInjection.inner_module_is_readmodel_spec — a
   structurally-detected read-model-shaped inline module gets a
   [let visibility] field so it satisfies ReadModel.Spec / StateViewSlice.Spec. *)

let body_has_schema_state (body : structure) : bool =
  List.exists (fun (item : structure_item) ->
    match item.pstr_desc with
    | Pstr_type (_, decls) ->
      List.exists (fun (td : type_declaration) ->
        String.equal td.ptype_name.txt "state"
        && Util.has_attr "schema" td.ptype_attributes
      ) decls
    | _ -> false
  ) body

let inner_module_is_readmodel_spec (mb : module_binding) : bool =
  match mb.pmb_expr.pmod_desc with
  | Pmod_structure body ->
    body_has_schema_state body
    && Util.has_let_binding "subIdConfig" body
  | _ -> false

let inject_into_inner_module ~loc (mb : module_binding) : module_binding =
  match mb.pmb_expr.pmod_desc with
  | Pmod_structure body ->
    if Util.has_let_binding "visibility" body then mb
    else
      let user_value = extract_file_value body in
      let body = strip_file_visibility_attrs body in
      let needs_open =
        Option.is_some user_value
        && not (Util.has_open_dotted "Reventless" "Visibility" body)
      in
      let prefix = if needs_open then [gen_open_visibility ~loc] else [] in
      let value = match user_value with
        | Some e -> e
        | None -> default_expr ~loc
      in
      let new_body = prefix @ body @ [gen_visibility ~loc value] in
      { mb with pmb_expr = { mb.pmb_expr with pmod_desc = Pmod_structure new_body } }
  | _ -> mb

(* Walk a structure and inject visibility on any read-model-shaped inner
   module. Safe to run unconditionally — files with no inline read-model
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
    | Pstr_module mb when inner_module_is_readmodel_spec mb ->
      let mb' = inject_into_inner_module ~loc:item.pstr_loc mb in
      { item with pstr_desc = Pstr_module mb' }
    | _ -> item
  ) str
