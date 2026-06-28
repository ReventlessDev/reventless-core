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

(* let commandAuthorization = command => switch command { … | _ => default }.
   Per-constructor rules become explicit cases; un-annotated constructors
   fall through to the default. When [exhaustive] (every constructor of the
   command type carries a rule), the wildcard default case is omitted — a
   wildcard after an exhaustive set of explicit cases is unused and trips
   ReScript's warning 11 (e.g. a single-constructor [@authorize] command). *)
let gen_command_authorization_switch
    ~loc
    ~(per_constructor_rules : (string * bool * expression) list)
    ~(default_rule : expression)
    ~(exhaustive : bool) =
  let cases =
    List.map (fun (name, has_payload, rule) ->
      let cstr_lid = { txt = Lident name; loc } in
      let lhs =
        if has_payload
        then Ast_builder.Default.ppat_construct ~loc cstr_lid (Some (Ast_builder.Default.ppat_any ~loc))
        else Ast_builder.Default.ppat_construct ~loc cstr_lid None
      in
      { pc_lhs = lhs; pc_guard = None; pc_rhs = rule }
    ) per_constructor_rules
  in
  let cases =
    if exhaustive then cases
    else
      let wildcard_case = {
        pc_lhs = Ast_builder.Default.ppat_any ~loc;
        pc_guard = None;
        pc_rhs = default_rule;
      } in
      cases @ [wildcard_case]
  in
  let cmd_var_pat = Ast_builder.Default.ppat_var ~loc { txt = "command"; loc } in
  let cmd_var_ident =
    Ast_builder.Default.pexp_ident ~loc { txt = Lident "command"; loc }
  in
  let switch = Ast_builder.Default.pexp_match ~loc cmd_var_ident cases in
  let fn = Ast_builder.Default.pexp_fun ~loc Nolabel None cmd_var_pat switch in
  let pat = Ast_builder.Default.ppat_var ~loc { txt = "commandAuthorization"; loc } in
  Ast_builder.Default.pstr_value ~loc Nonrecursive
    [Ast_builder.Default.value_binding ~loc ~pat ~expr:fn]

(* Per-constructor `@authorize(rule)` extraction --------------------------- *)
(* Scans the `command` variant type for `@authorize(rule)` constructor
   attributes. Returns [(constructor_name, has_payload, rule_expression)]
   for each annotated constructor. Empty list when no constructor carries
   the annotation — caller falls back to the constant-lambda form. *)
let extract_constructor_rules (body : structure) : (string * bool * expression) list =
  List.concat_map (fun (item : structure_item) ->
    match item.pstr_desc with
    | Pstr_type (_, decls) ->
      List.concat_map (fun (td : type_declaration) ->
        if String.equal td.ptype_name.txt "command"
           && Util.has_attr "schema" td.ptype_attributes
        then
          match td.ptype_kind with
          | Ptype_variant ctors ->
            List.filter_map (fun (cd : constructor_declaration) ->
              let authorize_attr =
                List.find_opt (fun (attr : attribute) ->
                  String.equal attr.attr_name.txt "authorize"
                ) cd.pcd_attributes
              in
              match authorize_attr with
              | None -> None
              | Some attr ->
                (match attr.attr_payload with
                 | PStr [{ pstr_desc = Pstr_eval (expr, _); _ }] ->
                   let has_payload = match cd.pcd_args with
                     | Pcstr_tuple [] -> false
                     | _ -> true
                   in
                   Some (cd.pcd_name.txt, has_payload, expr)
                 | _ -> None)
            ) ctors
          | _ -> []
        else []
      ) decls
    | _ -> []
  ) body

(* Total number of constructors in the `@schema type command` variant. Used to
   decide whether the per-constructor rules are exhaustive (every constructor
   annotated) and the switch can drop its wildcard default. Returns 0 when
   `command` is absent or not a variant (record/abstract) — callers then keep
   the wildcard. *)
let count_command_constructors (body : structure) : int =
  List.fold_left (fun acc (item : structure_item) ->
    match item.pstr_desc with
    | Pstr_type (_, decls) ->
      List.fold_left (fun acc (td : type_declaration) ->
        if String.equal td.ptype_name.txt "command"
           && Util.has_attr "schema" td.ptype_attributes
        then
          match td.ptype_kind with
          | Ptype_variant ctors -> acc + List.length ctors
          | _ -> acc
        else acc
      ) acc decls
    | _ -> acc
  ) 0 body

(* Per-constructor rules are exhaustive when every constructor of the command
   variant carries one — then the switch needs no wildcard default. *)
let rules_are_exhaustive (body : structure)
    (per_constructor_rules : (string * bool * expression) list) : bool =
  let total = count_command_constructors body in
  total > 0 && List.length per_constructor_rules = total

(* Strip `@authorize` from constructor declarations in the `command` type so
   sury-ppx (which runs after us) doesn't see an unknown attribute. *)
let strip_authorize_attrs_from_command (body : structure) : structure =
  List.map (fun (item : structure_item) ->
    match item.pstr_desc with
    | Pstr_type (rec_flag, decls) ->
      let new_decls = List.map (fun (td : type_declaration) ->
        if String.equal td.ptype_name.txt "command"
           && Util.has_attr "schema" td.ptype_attributes
        then
          match td.ptype_kind with
          | Ptype_variant ctors ->
            let new_ctors = List.map (fun (cd : constructor_declaration) ->
              { cd with pcd_attributes =
                  List.filter (fun (attr : attribute) ->
                    not (String.equal attr.attr_name.txt "authorize")
                  ) cd.pcd_attributes }
            ) ctors in
            { td with ptype_kind = Ptype_variant new_ctors }
          | _ -> td
        else td
      ) decls in
      { item with pstr_desc = Pstr_type (rec_flag, new_decls) }
    | _ -> item
  ) body

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
  let pick
      ~(per_constructor_rules : (string * bool * expression) list)
      (user_rule : expression option)
      (body_after_strip : structure) =
    let has_user_payload =
      Option.is_some user_rule || List.length per_constructor_rules > 0
    in
    let needs_open =
      has_user_payload
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
    let per_constructor_rules = extract_constructor_rules body in
    let body = strip_file_authorize_attrs body in
    let body = strip_authorize_attrs_from_command body in
    let (prefix, default_rule) = pick ~per_constructor_rules user_rule body in
    let exhaustive = rules_are_exhaustive body per_constructor_rules in
    let suffix =
      if Util.has_let_binding "commandAuthorization" body
      then []
      else if List.length per_constructor_rules > 0
      then [gen_command_authorization_switch ~loc ~per_constructor_rules ~default_rule ~exhaustive]
      else [gen_command_authorization ~loc default_rule]
    in
    (prefix, body, suffix)
  | QueryCarrier ->
    let user_rule = extract_file_rule body in
    let body = strip_file_authorize_attrs body in
    let (prefix, rule) = pick ~per_constructor_rules:[] user_rule body in
    let suffix =
      if Util.has_let_binding "authorization" body
      then []
      else [gen_authorization ~loc rule]
    in
    (prefix, body, suffix)

(* externalSystem auto-injection for translation slices ---------------------- *)
(* [let externalSystem = None] — the opt-in display name of the foreign system a
   translation slice integrates with. It drives the "external box" drawn outside the
   plugin in the Event Graph / Context Map (docs/plans/translation-external-boxes.md).
   Injected for Inbound/Outbound translation specs that don't already declare it, so
   existing specs satisfy the [Spec] module type without a hand-written [= None]. A spec
   that names its system (`let externalSystem = Some("…")`) wins — idempotent. *)
let gen_external_system ~loc =
  let none = Ast_builder.Default.pexp_construct ~loc { txt = Lident "None"; loc } None in
  let pat = Ast_builder.Default.ppat_var ~loc { txt = "externalSystem"; loc } in
  Ast_builder.Default.pstr_value ~loc Nonrecursive
    [Ast_builder.Default.value_binding ~loc ~pat ~expr:none]

let is_translation_folder fname =
  Util.is_in_folder fname "InboundTranslationSlice"
  || Util.is_in_folder fname "InboundTranslationSlices"
  || Util.is_in_folder fname "OutboundTranslationSlice"
  || Util.is_in_folder fname "OutboundTranslationSlices"

(* Suffix to splice after the spec body — [] unless this is a translation spec
   missing the binding. Shares the [is_spec_namespace_pkg] skip with [inject]. *)
let external_system_suffix ~loc fname (body : structure) : structure_item list =
  if is_spec_namespace_pkg loc then []
  else if is_translation_folder fname && not (Util.has_let_binding "externalSystem" body)
  then [gen_external_system ~loc]
  else []

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

(* Inbound translation specs carry [@schema type externalInput]; outbound ones
   [@schema type outboundItem] — either marks a translation spec needing the
   optional [externalSystem] field. (Inbound also has [@schema type command], so it
   ALSO matches the aggregate shape and gets commandAuthorization; the two
   injections compose.) *)
let inner_module_is_translation_spec (mb : module_binding) : bool =
  match mb.pmb_expr.pmod_desc with
  | Pmod_structure body ->
    body_has_schema_type "externalInput" body || body_has_schema_type "outboundItem" body
  | _ -> false

(* Append [let externalSystem = None] to an inline translation spec lacking it. *)
let inject_external_system_into_inner_module ~loc (mb : module_binding) : module_binding =
  match mb.pmb_expr.pmod_desc with
  | Pmod_structure body when not (Util.has_let_binding "externalSystem" body) ->
    let new_body = body @ [gen_external_system ~loc] in
    { mb with pmb_expr = { mb.pmb_expr with pmod_desc = Pmod_structure new_body } }
  | _ -> mb

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
      let per_constructor_rules =
        if is_command_carrier then extract_constructor_rules body else []
      in
      let body = strip_file_authorize_attrs body in
      let body =
        if is_command_carrier then strip_authorize_attrs_from_command body else body
      in
      let has_user_payload =
        Option.is_some user_rule || List.length per_constructor_rules > 0
      in
      let needs_open =
        has_user_payload
        && not (Util.has_open_dotted "Reventless" "Authorization" body)
      in
      let prefix = if needs_open then [gen_open_authorization ~loc] else [] in
      let default_rule = match user_rule with
        | Some e -> e
        | None -> default_rule_expr ~loc
      in
      let injection =
        if is_command_carrier then
          if List.length per_constructor_rules > 0
          then
            let exhaustive = rules_are_exhaustive body per_constructor_rules in
            gen_command_authorization_switch ~loc ~per_constructor_rules ~default_rule ~exhaustive
          else gen_command_authorization ~loc default_rule
        else gen_authorization ~loc default_rule
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
    let loc = item.pstr_loc in
    match item.pstr_desc with
    | Pstr_module mb when inner_module_is_aggregate_spec mb ->
      (* Inbound translation specs also match the aggregate shape (they declare a
         command): inject commandAuthorization AND, when it's a translation,
         externalSystem. *)
      let mb' = inject_into_inner_module ~loc ~is_command_carrier:true mb in
      let mb' =
        if inner_module_is_translation_spec mb'
        then inject_external_system_into_inner_module ~loc mb'
        else mb'
      in
      { item with pstr_desc = Pstr_module mb' }
    | Pstr_module mb when inner_module_is_readmodel_spec mb ->
      let mb' = inject_into_inner_module ~loc ~is_command_carrier:false mb in
      { item with pstr_desc = Pstr_module mb' }
    | Pstr_module mb when inner_module_is_translation_spec mb ->
      (* Outbound translation specs (outboundItem, no command): externalSystem only. *)
      let mb' = inject_external_system_into_inner_module ~loc mb in
      { item with pstr_desc = Pstr_module mb' }
    | _ -> item
  ) str
