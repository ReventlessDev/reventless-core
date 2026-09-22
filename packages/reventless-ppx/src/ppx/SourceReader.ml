(* SourceReader.ml — the declarations of one ReScript file, with their spans.

   Tools that edit source in place replace one span and leave everything around
   it (comments, helpers, formatting) as written, so they need to know where
   each thing is. This walk reports, for one parsed file:

   - its file-level attributes and `open`s;
   - each type with its cases, fields and attributes;
   - each top-level `let`, with a function's parameters and defaults;
   - each `describe` / `test` of a GWT file, with its scenario-id marker and
     the values of its steps.

   A span is `{"start", "end"}` in BYTE offsets into the file, as the parser set
   them. Every node also carries the source text its span cuts, so a caller that
   only reads needs no offsets. Nothing is evaluated or printed from the tree:
   the printer writes OCaml syntax, not ReScript.

   The parse is the compiler's. `read/read.ml` has bsc hand the tree over as it
   does to the PPX (see docs/plans/source-reader-with-spans.md, S0 verdict). *)

open Ppxlib

let flatten = SidecarEmit.flatten_longident

(* ── spans and text ─────────────────────────────────────────────────────── *)

let span_json (a : int) (b : int) : Yojson.Safe.t =
  `Assoc [ ("start", `Int a); ("end", `Int b) ]

let cut ~src a b =
  if a >= 0 && b >= a && b <= String.length src then String.sub src a (b - a) else ""

(* A location's byte span: see [SidecarEmit.byte_offset] for why pos_cnum is not
   one after a non-ASCII character. *)
let byte_of ~src (p : Lexing.position) = SidecarEmit.byte_offset src p

let span_of ~src (loc : Location.t) = (byte_of ~src loc.loc_start, byte_of ~src loc.loc_end)

(* `span` and `text` of a byte span, as the fields every node starts with. *)
let at_span ~src ((a, b) : int * int) : (string * Yojson.Safe.t) list =
  [ ("span", span_json a b); ("text", `String (cut ~src a b)) ]

let at ~src (loc : Location.t) = at_span ~src (span_of ~src loc)

(* ── attributes ─────────────────────────────────────────────────────────── *)

(* Attributes the parser adds as printing hints (`res.braces`, `res.arity`, …)
   are not something an author wrote. `res.optional` is reported as a field's
   `optional`; a doc comment (`res.doc`) is reported like any other attribute. *)
let is_authored (a : attribute) =
  let n = a.attr_name.txt in
  String.equal n "res.doc"
  || not (String.length n >= 4 && String.equal (String.sub n 0 4) "res.")
     && not (String.equal n "ocaml.ppx.context")

(* An attribute's location covers its name only (`@ref`), so its span runs on
   to the end of its payload and the `)` that closes it. *)
let attribute_json ~src (a : attribute) : Yojson.Safe.t =
  let start = byte_of ~src a.attr_loc.loc_start in
  let args, stop =
    match a.attr_payload with
    | PStr (_ :: _ as items) ->
      let first = byte_of ~src (List.hd items).pstr_loc.loc_start in
      let last = byte_of ~src (List.nth items (List.length items - 1)).pstr_loc.loc_end in
      let rec close i =
        if i >= String.length src then last
        else match src.[i] with
          | ' ' | '\t' | '\n' | '\r' -> close (i + 1)
          | ')' -> i + 1
          | _ -> last
      in
      (`String (cut ~src first last), close last)
    | _ -> (`Null, byte_of ~src a.attr_loc.loc_end)
  in
  `Assoc
    [ ("name", `String a.attr_name.txt);
      ("args", args);
      ("span", span_json start stop);
      ("text", `String (cut ~src start stop)) ]

let attributes_json ~src attrs =
  `List (List.map (attribute_json ~src) (List.filter is_authored attrs))

(* ── types ──────────────────────────────────────────────────────────────── *)

let type_text ~src (ct : core_type) : Yojson.Safe.t = `Assoc (at ~src ct.ptyp_loc)

let field_json ~src (ld : label_declaration) : Yojson.Safe.t =
  `Assoc
    ([ ("name", `String ld.pld_name.txt);
       ("optional", `Bool (SidecarEmit.has_attr "res.optional" ld.pld_attributes));
       ("mutable", `Bool (ld.pld_mutable = Mutable));
       ("type", type_text ~src ld.pld_type);
       ("attributes", attributes_json ~src ld.pld_attributes) ]
     @ at ~src ld.pld_loc)

let case_json ~src (c : constructor_declaration) : Yojson.Safe.t =
  let payload =
    match c.pcd_args with
    | Pcstr_record lds -> [ ("fields", `List (List.map (field_json ~src) lds)) ]
    | Pcstr_tuple [] -> []
    | Pcstr_tuple cts -> [ ("args", `List (List.map (type_text ~src) cts)) ]
  in
  `Assoc
    ([ ("name", `String c.pcd_name.txt);
       ("attributes", attributes_json ~src c.pcd_attributes) ]
     @ payload @ at ~src c.pcd_loc)

let type_json ~src (td : type_declaration) : Yojson.Safe.t =
  let shape =
    match td.ptype_kind, td.ptype_manifest with
    | Ptype_variant cs, _ -> [ ("kind", `String "variant"); ("cases", `List (List.map (case_json ~src) cs)) ]
    | Ptype_record lds, _ -> [ ("kind", `String "record"); ("fields", `List (List.map (field_json ~src) lds)) ]
    | Ptype_open, _ -> [ ("kind", `String "open") ]
    | Ptype_abstract, Some ct -> [ ("kind", `String "alias"); ("manifest", type_text ~src ct) ]
    | Ptype_abstract, None -> [ ("kind", `String "abstract") ]
  in
  `Assoc
    ([ ("name", `String td.ptype_name.txt);
       ("attributes", attributes_json ~src td.ptype_attributes) ]
     @ shape @ at ~src td.ptype_loc)

(* ── expressions ────────────────────────────────────────────────────────── *)

let label_json = function
  | Nolabel -> `Null
  | Labelled s -> `String ("~" ^ s)
  | Optional s -> `String ("?" ^ s)

(* The parser folds a minus into the constant it negates (`-2`, `-.3.5`) but keeps
   the location of the digits, so the span would cut `2`. A negative constant's
   span starts at its `-` (or `-.`), over any space between. *)
let constant_span ~src (loc : Location.t) (value : string) : int * int =
  let a, b = span_of ~src loc in
  if String.length value = 0 || value.[0] <> '-' then (a, b)
  else
    let rec back i =
      if i < 0 then None
      else match src.[i] with
        | ' ' | '\t' | '\n' | '\r' -> back (i - 1)
        | '-' -> Some i
        | '.' when i > 0 && src.[i - 1] = '-' -> Some (i - 1)
        | _ -> None
    in
    match back (a - 1) with
    | Some i -> (i, b)
    | None -> (a, b)

(* An outline of an expression: what a value is built from, each part with its
   span. Anything this walk does not name is `other`, with its text. *)
let rec expr_json ~src (e : expression) : Yojson.Safe.t =
  let node ?span kind fields =
    let span = match span with Some s -> s | None -> span_of ~src e.pexp_loc in
    `Assoc ((("kind", `String kind) :: fields) @ at_span ~src span)
  in
  match e.pexp_desc with
  | Pexp_constant (Pconst_string (s, _, _)) -> node "string" [ ("value", `String s) ]
  | Pexp_constant (Pconst_integer (s, _)) ->
    node ~span:(constant_span ~src e.pexp_loc s) "int" [ ("value", `String s) ]
  | Pexp_constant (Pconst_float (s, _)) ->
    node ~span:(constant_span ~src e.pexp_loc s) "float" [ ("value", `String s) ]
  | Pexp_construct ({ txt = Lident "Function$"; _ }, Some inner) -> function_json ~src ~outer:e inner
  | Pexp_fun _ -> function_json ~src ~outer:e e
  | Pexp_construct ({ txt; _ }, payload) ->
    node "constructor"
      [ ("name", `String (flatten txt));
        ("payload", match payload with Some p -> expr_json ~src p | None -> `Null) ]
  | Pexp_ident { txt; _ } -> node "ident" [ ("name", `String (flatten txt)) ]
  | Pexp_array items -> node "array" [ ("items", `List (List.map (expr_json ~src) items)) ]
  | Pexp_record (fields, spread) ->
    let field ((lid : Longident.t loc), value) =
      `Assoc
        [ ("name", `String (flatten lid.txt));
          ("span", span_json (byte_of ~src lid.loc.loc_start) (byte_of ~src value.pexp_loc.loc_end));
          ("value", expr_json ~src value) ]
    in
    node "record"
      [ ("fields", `List (List.map field fields));
        ("spread", match spread with Some s -> expr_json ~src s | None -> `Null) ]
  | Pexp_apply (fn, args) ->
    let arg (lbl, value) = `Assoc [ ("label", label_json lbl); ("value", expr_json ~src value) ] in
    node "call"
      [ ("fn", match fn.pexp_desc with
          | Pexp_ident { txt; _ } -> `String (flatten txt)
          | _ -> `Null);
        ("args", `List (List.map arg args)) ]
  | Pexp_constraint (inner, ct) ->
    node "constraint" [ ("value", expr_json ~src inner); ("type", type_text ~src ct) ]
  | _ -> node "other" []

(* `(~id, ~name, ~price=2500.0): orderLine => body`. The parameters and return
   type come from the nested `Pexp_fun`s; `outer` is the whole function, whose
   span includes the `Function$` wrapper ReScript v12 adds. *)
and function_json ~src ~(outer : expression) (e : expression) : Yojson.Safe.t =
  let rec collect (e : expression) acc =
    match e.pexp_desc with
    | Pexp_fun (lbl, default, pat, body) ->
      let param =
        `Assoc
          ([ ("label", label_json lbl);
             ("default", match default with Some d -> expr_json ~src d | None -> `Null) ]
           @ at ~src pat.ppat_loc)
      in
      collect body (param :: acc)
    | Pexp_construct ({ txt = Lident "Function$"; _ }, Some inner) -> collect inner acc
    | _ -> (List.rev acc, e)
  in
  let params, body = collect e [] in
  let return_type, body =
    match body.pexp_desc with
    | Pexp_constraint (inner, ct) -> (type_text ~src ct, inner)
    | _ -> (`Null, body)
  in
  `Assoc
    ([ ("kind", `String "function");
       ("params", `List params);
       ("returnType", return_type);
       ("body", expr_json ~src body) ]
     @ at ~src outer.pexp_loc)

(* ── top-level lets and opens ───────────────────────────────────────────── *)

let let_json ~src ~recursive (vb : value_binding) : Yojson.Safe.t =
  let name, typ =
    match vb.pvb_pat.ppat_desc with
    | Ppat_var { txt; _ } -> (`String txt, `Null)
    | Ppat_constraint ({ ppat_desc = Ppat_var { txt; _ }; _ }, ct) -> (`String txt, type_text ~src ct)
    | _ -> (`Null, `Null)
  in
  (* A `let x: T = v` binding reaches the tree with the annotation on both the
     pattern and the value; the value is what was written after `=`. *)
  let value =
    match vb.pvb_expr.pexp_desc, typ with
    | Pexp_constraint (inner, _), `Assoc _ -> inner
    | _ -> vb.pvb_expr
  in
  `Assoc
    ([ ("name", name);
       ("recursive", `Bool recursive);
       ("type", typ);
       ("value", expr_json ~src value);
       ("attributes", attributes_json ~src vb.pvb_attributes) ]
     @ at ~src vb.pvb_loc)

let open_json ~src (od : open_declaration) : Yojson.Safe.t option =
  match od.popen_expr.pmod_desc with
  | Pmod_ident { txt; _ } -> Some (`Assoc ((("name", `String (flatten txt))) :: at ~src od.popen_loc))
  | _ -> None

(* ── GWT tests ──────────────────────────────────────────────────────────── *)

(* The step calls of one test body, in the order they run. The chain so far is
   an argument of each step (pipe-first) or of the pipe around it, so an
   argument that holds a step is the chain, not a value; the others are the
   step's values. Any other call is walked left to right, which keeps the order
   the steps are written in. *)
(* A step is any `given…` / `when…` / `then…` call, not only the verbs the
   sidecar knows: a translation's GWT module has its own (`whenIncomingEvent`,
   `thenPublishesCommand`), and a reader reports what is written. *)
let is_verb (lid : Longident.t) =
  let name = SidecarEmit.step_name_of lid in
  List.mem name SidecarEmit.step_names
  || List.exists
       (fun prefix ->
         let lp = String.length prefix in
         String.length name > lp
         && String.equal (String.sub name 0 lp) prefix
         && Char.uppercase_ascii name.[lp] = name.[lp]
         && Char.lowercase_ascii name.[lp] <> name.[lp])
       [ "given"; "when"; "then" ]

let rec holds_step (e : expression) =
  match e.pexp_desc with
  | Pexp_apply ({ pexp_desc = Pexp_ident { txt; _ }; _ }, args) ->
    is_verb txt || List.exists (fun (_, a) -> holds_step a) args
  | Pexp_constraint (inner, _) -> holds_step inner
  | _ -> false

let rec collect_steps ~src (e : expression) (acc : Yojson.Safe.t list) : Yojson.Safe.t list =
  match e.pexp_desc with
  | Pexp_apply ({ pexp_desc = Pexp_ident { txt; _ }; _ }, args) when is_verb txt ->
    let acc = List.fold_left (fun acc (_, a) -> if holds_step a then collect_steps ~src a acc else acc) acc args in
    let values = List.filter (fun (_, a) -> not (holds_step a)) args in
    `Assoc
      [ ("verb", `String (SidecarEmit.step_name_of txt));
        ("args", `List (List.map (fun (_, a) -> expr_json ~src a) values)) ]
    :: acc
  (* `->thenNoEvent` has no parentheses: the pipe's right side is the verb
     itself, a step with no values. *)
  | Pexp_ident { txt; _ } when is_verb txt ->
    `Assoc [ ("verb", `String (SidecarEmit.step_name_of txt)); ("args", `List []) ] :: acc
  | Pexp_apply (_, args) -> List.fold_left (fun acc (_, a) -> collect_steps ~src a acc) acc args
  | Pexp_let (_, _, cont) -> collect_steps ~src cont acc
  | Pexp_sequence (a, b) -> collect_steps ~src b (collect_steps ~src a acc)
  | Pexp_constraint (inner, _) -> collect_steps ~src inner acc
  | _ -> acc

let describe_json ~src ~scenario_ids ~test_lines (item : structure_item) : Yojson.Safe.t option =
  match SidecarEmit.describe_of_item item with
  | None -> None
  | Some (name, tests) ->
    let test ((loc : Location.t), title, body) =
      let marker =
        match SidecarEmit.scenario_id_for loc.loc_start.pos_lnum ~tests:test_lines scenario_ids with
        | Some id -> `String id
        | None -> `Null
      in
      `Assoc
        ([ ("title", `String title);
           ("scenarioId", marker);
           ("steps", `List (List.rev (collect_steps ~src body []))) ]
         @ at ~src loc)
    in
    Some
      (`Assoc
         ([ ("describe", `String name); ("tests", `List (List.map test tests)) ]
          @ at ~src item.pstr_loc))

(* ── the file ───────────────────────────────────────────────────────────── *)

let file_json ~(fname : string) ~(src : string) (str : structure) : Yojson.Safe.t =
  let scenario_ids = SidecarEmit.scenario_ids_of_source src in
  let test_lines =
    List.concat_map
      (fun item ->
        match SidecarEmit.describe_of_item item with
        | Some (_, tests) -> List.map (fun ((l : Location.t), _, _) -> l.loc_start.pos_lnum) tests
        | None -> [])
      str
  in
  let pick f = List.concat_map f str in
  `Assoc
    [ ("file", `String fname);
      ( "attributes",
        `List
          (pick (fun it ->
               match it.pstr_desc with
               | Pstr_attribute a when is_authored a -> [ attribute_json ~src a ]
               | _ -> [])) );
      ( "opens",
        `List
          (pick (fun it ->
               match it.pstr_desc with
               | Pstr_open od -> Option.to_list (open_json ~src od)
               | _ -> [])) );
      ( "types",
        `List
          (pick (fun it ->
               match it.pstr_desc with
               | Pstr_type (_, tds) -> List.map (type_json ~src) tds
               | _ -> [])) );
      ( "lets",
        `List
          (pick (fun it ->
               match it.pstr_desc with
               | Pstr_value (rf, vbs) -> List.map (let_json ~src ~recursive:(rf = Recursive)) vbs
               | _ -> [])) );
      ( "describes",
        `List (pick (fun it -> Option.to_list (describe_json ~src ~scenario_ids ~test_lines it))) ) ]
