(* Authorization auto-injection for @@reventless.spec files.

   File-level [@@reventless.authorize(<rule>)] overrides the framework
   default ([AllowAuthenticated]). The PPX synthesises one of:

     let commandAuthorization = _ => <rule>     (* Aggregate, StateChangeSlice, InboundTranslationSlice *)
     let authorization        = <rule>          (* ReadModel, StateViewSlice, StateViewSliceStream *)

   No injection happens if the user already declared the binding. Adds
   [open Reventless.Authorization] to the prefix so the rule constructors
   (AllowAuthenticated, AllowGroups, …) resolve unqualified inside
   [@@reventless.authorize(...)] payloads.

   Per-constructor [@authorize(<rule>)] on individual [type command]
   constructors is a planned extension — not in this commit. *)

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
let inject ~loc fname (body : structure) : structure_item list * structure * structure_item list =
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
  match detect_kind fname with
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
