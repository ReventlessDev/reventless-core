(* Aggregate-behavior snapshot-config injection.

   [Behavior.T.snapshot : option<Snapshot.config<state>>] is a required
   module-type field (docs/plans/done/aggregate-snapshotting.md). This transform
   keeps every aggregate behavior file source-compatible by synthesising the
   default, and provides the opt-in sugar:

     (nothing)                          -> let snapshot = None
     [@@@reventless.snapshots 100]      -> let snapshot =
                                             Some({Reventless.Snapshot.interval: 100,
                                                   stateSchema: stateSchema})

   The [Some] form references [stateSchema], the binding sury-ppx generates
   from [@schema type state] — reventless-ppx runs before sury-ppx, so the
   reference resolves once sury has processed the type. The attribute is
   rejected when the file has no [@schema type state] (sury would never
   generate the schema) and on non-aggregate behavior files (StateChangeSlice
   behaviors satisfy a different module type without [snapshot]; snapshotting
   DCB slices is a non-goal — the decision-model cache is their analogue).

   No injection happens if the user already declared the binding. Mirrors
   [ReadConsistencyInjection] (attribute handling) and the [externalSystem]
   suffix in [AuthorizationInjection] (optional-field default). *)

open Ppxlib

let attr_txt = "reventless.snapshots"

let is_aggregate_folder fname =
  Util.is_in_folder fname "Aggregate" || Util.is_in_folder fname "Aggregates"

(* @@reventless.snapshots(<expr>) extraction ---------------------------- *)

let extract_file_value (str : structure) : expression option =
  let rec scan = function
    | [] -> None
    | item :: rest ->
      (match item.pstr_desc with
       | Pstr_attribute attr when String.equal attr.attr_name.txt attr_txt ->
         (match attr.attr_payload with
          | PStr [{ pstr_desc = Pstr_eval (expr, _); _ }] -> Some expr
          | _ -> None)
       | _ -> scan rest)
  in
  scan str

let strip_file_attrs (str : structure) : structure =
  List.filter (fun (item : structure_item) ->
    match item.pstr_desc with
    | Pstr_attribute attr -> not (String.equal attr.attr_name.txt attr_txt)
    | _ -> true
  ) str

let has_file_attr (str : structure) : bool =
  List.exists (fun (item : structure_item) ->
    match item.pstr_desc with
    | Pstr_attribute attr -> String.equal attr.attr_name.txt attr_txt
    | _ -> false
  ) str

(* Structural marker: sury only generates [stateSchema] from an annotated
   state type, so the Some(...) form is a compile error waiting to happen
   without it — reject early with a targeted message. *)
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

(* Generators ----------------------------------------------------------- *)

(* let snapshot = None *)
let gen_none ~loc =
  let pat = Ast_builder.Default.ppat_var ~loc { txt = "snapshot"; loc } in
  let expr =
    Ast_builder.Default.pexp_construct ~loc { txt = Lident "None"; loc } None
  in
  Ast_builder.Default.pstr_value ~loc Nonrecursive
    [Ast_builder.Default.value_binding ~loc ~pat ~expr]

(* let snapshot = Some({Reventless.Snapshot.interval: <expr>, stateSchema: stateSchema}) *)
let gen_some ~loc interval_expr =
  let record =
    Ast_builder.Default.pexp_record ~loc
      [ ( { txt = Ldot (Ldot (Lident "Reventless", "Snapshot"), "interval"); loc },
          interval_expr );
        ( { txt = Lident "stateSchema"; loc },
          Ast_builder.Default.pexp_ident ~loc { txt = Lident "stateSchema"; loc } );
      ]
      None
  in
  let expr =
    Ast_builder.Default.pexp_construct ~loc { txt = Lident "Some"; loc } (Some record)
  in
  let pat = Ast_builder.Default.ppat_var ~loc { txt = "snapshot"; loc } in
  Ast_builder.Default.pstr_value ~loc Nonrecursive
    [Ast_builder.Default.value_binding ~loc ~pat ~expr]

(* Injection — Behavior implementation files only (the caller gates on the
   Behavior kind). Returns the body with the attribute consumed plus the
   suffix to splice after it. *)
let inject ~loc fname (body : structure) : structure * structure_item list =
  if is_aggregate_folder fname then begin
    let user_value = extract_file_value body in
    let has_attr = has_file_attr body in
    let body = strip_file_attrs body in
    if has_attr && Option.is_none user_value then
      Location.raise_errorf ~loc
        "[reventless-ppx] @@@@reventless.snapshots expects an interval payload, e.g. @@@@reventless.snapshots(100).";
    if Option.is_some user_value && not (body_has_schema_state body) then
      Location.raise_errorf ~loc
        "[reventless-ppx] @@@@reventless.snapshots requires `@schema type state` in this file (the snapshot is serialized with the generated stateSchema).";
    if Util.has_let_binding "snapshot" body then begin
      if has_attr then
        Location.raise_errorf ~loc
          "[reventless-ppx] @@@@reventless.snapshots conflicts with the manual `let snapshot` binding in this file — keep one.";
      (body, [])
    end
    else
      let suffix = match user_value with
        | Some interval -> [gen_some ~loc interval]
        | None -> [gen_none ~loc]
      in
      (body, suffix)
  end
  else if has_file_attr body then
    Location.raise_errorf ~loc
      "[reventless-ppx] @@@@reventless.snapshots is only supported on Aggregate behavior files (Aggregate/<Entity>_Behavior.res). Snapshotting DCB slices is not supported — the decision-model cache covers them."
  else (body, [])
