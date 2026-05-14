(* Authorization auto-injection.

   Two injection paths share the same generator helpers:

   1. File-level (top-level `Spec` mode driven by `@@reventless.spec`):
      synthesises `let commandAuthorization` / `let authorization` at the
      end of the file, based on folder kind. See [inject].

   2. Inline-module (test fixtures, framework-internal Counter_Builder,
      etc.) where a `module FooSpec = { … }` carries an `@schema type
      command` or `@schema type state` directly. Structural detection +
      injection mean these inline specs don't need any hand-written auth
      boilerplate. See [walk_inline_specs].

   File-level [@@reventless.authorize(<rule>)] (or an inner-level
   equivalent inside a structurally-detected inline spec module)
   overrides the framework default ([AllowAuthenticated]). The PPX
   synthesises one of:

     let commandAuthorization = _ => <rule>     (* Aggregate, StateChangeSlice, InboundTranslationSlice *)
     let authorization        = <rule>          (* ReadModel, StateViewSlice, StateViewSliceStream *)

   No injection happens if the user already declared the binding. Adds
   [open Reventless.Authorization] to the prefix only when the rule
   payload uses unqualified rule constructors (the default rule is
   emitted fully qualified). *)

open Ppxlib

(* Folder-based file kind ----------------------------------------------------- *)

type kind =
  | CommandCarrier   (* injects [let commandAuthorization] *)
  | QueryCarrier     (* injects [let authorization] *)
  | Other            (* no injection *)

let detect_kind fname =
  if Util.is_in_aggregate_folder fname
     || Util.is_in_folder fname "StateChangeSlice"
     || Util.is_in_folder fname "StateChangeSlices"
     || Util.is_in_folder fname "InboundTranslationSlice"
     || Util.is_in_folder fname "InboundTranslationSlices"
  then CommandCarrier
  else if Util.is_in_readmodel_folder fname
       || Util.is_in_folder fname "StateViewSlice"
       || Util.is_in_folder fname "StateViewSliceStream"
       || Util.is_in_folder fname "StateViewSlices"
       || Util.is_in_folder fname "StateViewSliceStreams"
  then QueryCarrier
  else Other

(* Default rule: Reventless.Authorization.AllowAuthenticated ------------------ *)

let default_rule_expr ~loc =
  Ast_builder.Default.pexp_construct
    ~loc
    { txt = Ldot (Ldot (Lident "Reventless", "Authorization"), "AllowAuthenticated"); loc }
    None

(* @@reventless.authorize(<expr>) extraction --------------------------------- *)

let extract_file_rule (str : structure) : expression option =
  let rec scan = function
    | [] -> None
    | item :: rest ->
      (match item.pstr_desc with
       | Pstr_attribute attr when String.equal attr.attr_name.txt "reventless.authorize" ->
         (match attr.attr_payload with
          | PStr [{ pstr_desc = Pstr_eval (expr, _); _ }] -> Some expr
          | _ -> None)
       | _ -> scan rest)
  in
  scan str

let strip_file_authorize_attrs (str : structure) : structure =
  List.filter (fun (item : structure_item) ->
    match item.pstr_desc with
    | Pstr_attribute attr -> not (String.equal attr.attr_name.txt "reventless.authorize")
    | _ -> true
  ) str

(* Generators ---------------------------------------------------------------- *)

(* [open Reventless.Authorization] — added to the prefix so the rule
   constructors resolve unqualified in the payload of
   [@@reventless.authorize(...)]. *)
let gen_open_authorization ~loc =
  let lid = { txt = Ldot (Lident "Reventless", "Authorization"); loc } in
  { pstr_desc = Pstr_open {
      popen_expr = { pmod_desc = Pmod_ident lid; pmod_loc = loc; pmod_attributes = [] };
      popen_override = Fresh;
      popen_loc = loc;
      popen_attributes = [];
    };
    pstr_loc = loc }

(* let commandAuthorization = _ => <rule> *)
let gen_command_authorization ~loc rule =
  let wildcard = Ast_builder.Default.ppat_any ~loc in
  let fn = Ast_builder.Default.pexp_fun ~loc Nolabel None wildcard rule in
  let pat = Ast_builder.Default.ppat_var ~loc { txt = "commandAuthorization"; loc } in
  Ast_builder.Default.pstr_value ~loc Nonrecursive
    [Ast_builder.Default.value_binding ~loc ~pat ~expr:fn]

(* let authorization = <rule> *)
let gen_authorization ~loc rule =
  let pat = Ast_builder.Default.ppat_var ~loc { txt = "authorization"; loc } in
  Ast_builder.Default.pstr_value ~loc Nonrecursive
    [Ast_builder.Default.value_binding ~loc ~pat ~expr:rule]

(* Top-level injection helper used from ReventlessPpx.ml's Spec branch.
   Returns the (prefix_items, body, suffix_items) to splice into the spec
   file's structure. Idempotent on bodies that already declare the binding.

   [open Reventless.Authorization] is only added when the file actually
   uses an [@@reventless.authorize(<unqualified rule>)] payload — the
   default rule is emitted in fully-qualified form so no open is needed
   for the default case (avoiding "unused open" warnings on every spec). *)
(* Structural fallback for top-level spec files outside the folder
   convention (e.g. reventless-core/src/admin/PluginSpec.res — annotated
   with @@reventless.spec but living in admin/, not Aggregate/). The
   top-level Spec branch in ReventlessPpx will append `subIdConfig`
   later for readmodel-shaped files, so at injection time we only see
   `@schema type state` (not the let yet). Looser check is safe here
   because the file is already known to be a spec (carries
   @@reventless.spec). *)
let detect_kind_by_structure (body : structure) : kind =
  let has_schema_command =
    List.exists (fun (item : structure_item) ->
      match item.pstr_desc with
      | Pstr_type (_, decls) ->
        List.exists (fun (td : type_declaration) ->
          String.equal td.ptype_name.txt "command"
          && Util.has_attr "schema" td.ptype_attributes
        ) decls
      | _ -> false
    ) body
  in
  let has_schema_state =
    List.exists (fun (item : structure_item) ->
      match item.pstr_desc with
      | Pstr_type (_, decls) ->
        List.exists (fun (td : type_declaration) ->
          String.equal td.ptype_name.txt "state"
          && Util.has_attr "schema" td.ptype_attributes
        ) decls
      | _ -> false
    ) body
  in
  if has_schema_command then CommandCarrier
  else if has_schema_state then QueryCarrier
  else Other

(* Spec-namespace packages (CatalogSpec, OrderingSpec, …) are slim type-only
   packages that don't depend on reventless-spec. Skip injection there — the
   types they declare (ExtensionPoint protocols, etc.) satisfy module types
   that don't require authorization fields. *)
let is_spec_namespace_pkg loc =
  match ModuleUrl.find_package_for loc with
  | Some pkg -> ModuleUrl.is_spec_namespace pkg
  | None -> false

let inject ~loc fname (body : structure) : structure_item list * structure * structure_item list =
  if is_spec_namespace_pkg loc then ([], body, [])
  else
  let pick (user_rule : expression option) (body_after_strip : structure) =
    let needs_open =
      Option.is_some user_rule
      && not (Util.has_open_dotted "Reventless" "Authorization" body_after_strip)
    in
    let prefix = if needs_open then [gen_open_authorization ~loc] else [] in
    let rule = match user_rule with
      | Some e -> e
      | None -> default_rule_expr ~loc
    in
    (prefix, rule)
  in
  let kind = match detect_kind fname with
    | Other -> detect_kind_by_structure body
    | k -> k
  in
  match kind with
  | Other -> ([], body, [])
  | CommandCarrier ->
    let user_rule = extract_file_rule body in
    let body = strip_file_authorize_attrs body in
    let (prefix, rule) = pick user_rule body in
    let suffix =
      if Util.has_let_binding "commandAuthorization" body
      then []
      else [gen_command_authorization ~loc rule]
    in
    (prefix, body, suffix)
  | QueryCarrier ->
    let user_rule = extract_file_rule body in
    let body = strip_file_authorize_attrs body in
    let (prefix, rule) = pick user_rule body in
    let suffix =
      if Util.has_let_binding "authorization" body
      then []
      else [gen_authorization ~loc rule]
    in
    (prefix, body, suffix)

(* Inline-module detection + injection --------------------------------------- *)
(*
   Test fixtures and a handful of framework-internal helpers define spec
   modules inline:

     module FooSpec = {
       module Id = …
       let name = "Foo"
       @schema type command = …
     }

   The file-level PPX driver doesn't visit those, so without a separate
   walk they'd be missing [commandAuthorization] / [authorization] and
   fail signature checks against the Aggregate.Spec / ReadModel.Spec
   module types.

   Conservative structural detection picks them up without a marker
   attribute:

   - command-carrier: module body declares [@schema type command]
   - query-carrier: module body declares [@schema type state] AND
     [let subIdConfig] (the second predicate excludes Behavior modules
     that happen to declare their own [type state]).

   Idempotent on bodies that already declare the binding, so a hand-
   authored override in the inline spec wins over PPX defaults. *)

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

let inner_module_is_aggregate_spec (mb : module_binding) : bool =
  match mb.pmb_expr.pmod_desc with
  | Pmod_structure body -> body_has_schema_type "command" body
  | _ -> false

let inner_module_is_readmodel_spec (mb : module_binding) : bool =
  match mb.pmb_expr.pmod_desc with
  | Pmod_structure body ->
    body_has_schema_type "state" body
    && Util.has_let_binding "subIdConfig" body
  | _ -> false

(* Inject the appropriate field into an inline spec module body, if it
   isn't already present. Honours an inner [@@reventless.authorize(rule)]
   attribute the same way the file-level driver does. *)
let inject_into_inner_module
    ~loc
    ~(is_command_carrier : bool)
    (mb : module_binding) : module_binding =
  match mb.pmb_expr.pmod_desc with
  | Pmod_structure body ->
    let field_name = if is_command_carrier then "commandAuthorization" else "authorization" in
    if Util.has_let_binding field_name body then mb
    else
      let user_rule = extract_file_rule body in
      let body = strip_file_authorize_attrs body in
      let needs_open =
        Option.is_some user_rule
        && not (Util.has_open_dotted "Reventless" "Authorization" body)
      in
      let prefix = if needs_open then [gen_open_authorization ~loc] else [] in
      let rule = match user_rule with
        | Some e -> e
        | None -> default_rule_expr ~loc
      in
      let injection = if is_command_carrier
        then gen_command_authorization ~loc rule
        else gen_authorization ~loc rule
      in
      let new_body = prefix @ body @ [injection] in
      { mb with pmb_expr = { mb.pmb_expr with pmod_desc = Pmod_structure new_body } }
  | _ -> mb

(* Walk a structure and inject auth fields on any spec-shaped inner
   module. Safe to run unconditionally — files with no inline specs are
   a no-op AST traversal. Skipped entirely in *-spec packages
   (CatalogSpec, OrderingSpec, …) which don't depend on reventless-spec. *)
let walk_inline_specs (str : structure) : structure =
  let in_spec_pkg = match str with
    | item :: _ -> is_spec_namespace_pkg item.pstr_loc
    | [] -> false
  in
  if in_spec_pkg then str
  else
  List.map (fun (item : structure_item) ->
    match item.pstr_desc with
    | Pstr_module mb when inner_module_is_aggregate_spec mb ->
      let mb' = inject_into_inner_module ~loc:item.pstr_loc ~is_command_carrier:true mb in
      { item with pstr_desc = Pstr_module mb' }
    | Pstr_module mb when inner_module_is_readmodel_spec mb ->
      let mb' = inject_into_inner_module ~loc:item.pstr_loc ~is_command_carrier:false mb in
      { item with pstr_desc = Pstr_module mb' }
    | _ -> item
  ) str
