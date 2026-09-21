(* Toolchain-independent smoke test for SidecarEmit (Plan 06 Phase 1).
   Builds a representative spec AST via metaquot and asserts the emitted
   Model-fragment JSON has the right shape, dcbRole resolution, and config. *)

open Ppxlib

let loc = Location.none

(* A StateChangeSlice-shaped spec body: command + event with a @partitionTag
   id field, a @noDcbTag incidental id, plain fields, an error variant, plus a
   config constant. Mirrors what the forward emitter writes. *)
let body : structure =
  [%str
    type command =
      | AddProduct of
          { productId : string [@partitionTag]
          ; groupId : string [@noDcbTag]
          ; name : string
          ; price : float }
      [@@schema]

    type event =
      | ProductAdded of { productId : string [@partitionTag]; tags : string array }
      [@@schema]

    type error =
      | ProductAlreadyExists
      [@@schema]

    let maxRetries = 3
    let targetName = "OrderPlaced"]

let () =
  let j = ReventlessPpx__SidecarEmit.fragment_json ~spec_name:"AddProduct" ~fname:"AddProduct.res" body in
  let s = Yojson.Safe.to_string j in
  let must label needle =
    let contains hay sub =
      let lh = String.length hay and ls = String.length sub in
      let rec go i = i + ls <= lh && (String.equal (String.sub hay i ls) sub || go (i + 1)) in
      ls = 0 || go 0
    in
    if contains s needle then Printf.printf "  ok: %s\n" label
    else (Printf.printf "  FAIL: %s\n    missing %S in:\n%s\n" label needle s; exit 1)
  in
  must "specName" "\"specName\":\"AddProduct\"";
  must "command type" "\"typeName\":\"command\"";
  must "AddProduct element" "\"name\":\"AddProduct\"";
  must "partition role" "\"role\":\"partition\"";
  must "suppressed role" "\"role\":\"suppressed\"";
  must "noTag role (price)" "\"role\":\"noTag\"";
  must "float kind" "\"kind\":\"float\"";
  must "array→list kind" "\"kind\":\"list\"";
  must "error payloadless" "\"name\":\"ProductAlreadyExists\",\"payloadless\":true";
  must "config maxRetries" "\"key\":\"maxRetries\",\"value\":\"3\"";
  must "config targetName" "\"key\":\"targetName\",\"value\":\"\\\"OrderPlaced\\\"\"";
  print_string (Yojson.Safe.pretty_to_string j);
  print_newline ();

  (* ── GWT extraction (curried baseline) ──────────────────────────────────
     ReScript `describe("X", () => { test("t", () => a->f(b)->g(c)) })`
     reaches the ppx as multi-arg / nested applies. This block uses curried
     `fun` for the apply/step shapes; the callback-wrapper encoding that real
     ReScript v12 emits (`Function$`) is exercised in the block below. *)
  let gwt_body : structure =
    [%str
      describe "AddProduct" (fun () ->
          test "Adding a new product succeeds" (fun () ->
              thenEvent
                (whenCmd
                   (givenEvents [||])
                   (AddProduct { productId = "prod-1"; price = 9.99 }))
                (ProductAdded { productId = "prod-1"; price = 9.99 }));
          test "Adding a duplicate fails" (fun () ->
              thenError
                (whenCmd
                   (givenEvents [| ProductAdded { productId = "prod-1" } |])
                   (AddProduct { productId = "prod-1" }))
                ProductAlreadyExists);
          (* Accepted, and emitted nothing. The absence IS the assertion, so it
             has to reach the sidecar as a step of its own: a command that
             declares it guards a state without moving a row claims exactly
             this, and a step the sidecar cannot see is one a round trip
             rewrites into something else. Carries no payload, and pipe-first
             still makes it an apply whose argument is the chain rather than an
             element. *)
          test "Renaming a product moves nothing" (fun () ->
              thenNoEvent
                (whenCmd
                   (givenEvents [| ProductAdded { productId = "prod-1" } |])
                   (RenameProduct { productId = "prod-1" })));
          (* The plural form. `thenEvents([A, B])` is the only way to assert
             more than one event, and it used to record an EMPTY `then` —
             `element_of_constructor` answers None for an array literal, so the
             whole assertion was dropped. An empty `then` reads downstream as a
             command that ran and produced nothing, which is the opposite of
             what this asserts, and it made the lifecycle check call such a
             scenario a contradiction of the transition the command declares. *)
          test "Attaching an image reports what now stands" (fun () ->
              thenEvents
                (whenCmd
                   (givenEvents [| ProductAdded { productId = "prod-1" } |])
                   (AttachProductImage { productId = "prod-1" }))
                [| ProductImageAttached { productId = "prod-1" }
                 ; ProductEffectiveImageChanged { productId = "prod-1" }
                |]))]
  in
  let gj =
    match
      ReventlessPpx__SidecarEmit.gwt_fragment_json ~fname:"AddProduct_GWT.res" gwt_body
    with
    | Some j -> j
    | None -> (Printf.printf "  FAIL: gwt_fragment_json returned None\n"; exit 1)
  in
  let gs = Yojson.Safe.to_string gj in
  let gmust label needle =
    let contains hay sub =
      let lh = String.length hay and ls = String.length sub in
      let rec go i = i + ls <= lh && (String.equal (String.sub hay i ls) sub || go (i + 1)) in
      ls = 0 || go 0
    in
    if contains gs needle then Printf.printf "  ok(gwt): %s\n" label
    else (Printf.printf "  FAIL(gwt): %s\n    missing %S in:\n%s\n" label needle gs; exit 1)
  in
  gmust "gwt specName" "\"specName\":\"AddProduct\"";
  gmust "scenario title" "\"title\":\"Adding a new product succeeds\"";
  gmust "when command element" "\"kind\":\"command\",\"element\":\"AddProduct\"";
  gmust "then event element" "\"kind\":\"event\",\"element\":\"ProductAdded\"";
  gmust "then error element" "\"kind\":\"error\",\"element\":\"ProductAlreadyExists\"";
  gmust "then no-event step" "\"kind\":\"noEvent\",\"element\":\"\"";
  (* Both of them, in order: a plural assertion that recorded only its first
     event would still under-report what the scenario says. *)
  gmust "then events — first" "\"kind\":\"event\",\"element\":\"ProductImageAttached\"";
  gmust "then events — second"
    "\"kind\":\"event\",\"element\":\"ProductEffectiveImageChanged\"";
  gmust "given event (duplicate scenario)" "\"kind\":\"event\",\"element\":\"ProductAdded\"";
  gmust "float example value" "\"kind\":\"float\",\"value\":9.99";
  gmust "string example value" "\"kind\":\"string\",\"value\":\"prod-1\"";
  print_string (Yojson.Safe.pretty_to_string gj);
  print_newline ();

  (* ── GWT extraction over the REAL ReScript v12 encoding ──────────────────
     ReScript v12 wraps every lambda as `Function$(inner_fun)` — a
     `Pexp_construct (Lident "Function$", Some fun)` — so `describe`/`test`
     callbacks reach the ppx as a construct, not a bare `Pexp_fun`. The block
     above used curried `fun`, which does NOT reproduce that wrapper (the
     original "identical Parsetree shape" assumption was wrong, and the GWT
     sidecar silently emitted nothing for real builds). This re-runs the
     extraction over the wrapped form to lock the regression. *)
  let rec wrap_funs (e : expression) : expression =
    let e =
      { e with
        pexp_desc =
          (match e.pexp_desc with
           | Pexp_fun (l, d, p, body) -> Pexp_fun (l, d, p, wrap_funs body)
           | Pexp_apply (f, args) ->
             Pexp_apply (wrap_funs f, List.map (fun (l, a) -> (l, wrap_funs a)) args)
           | Pexp_sequence (a, b) -> Pexp_sequence (wrap_funs a, wrap_funs b)
           | other -> other) }
    in
    match e.pexp_desc with
    | Pexp_fun _ ->
      { e with
        pexp_desc =
          Pexp_construct ({ txt = Lident "Function$"; loc = e.pexp_loc }, Some e) }
    | _ -> e
  in
  let gwt_body_v12 : structure =
    List.map
      (fun item ->
        match item.pstr_desc with
        | Pstr_eval (e, attrs) -> { item with pstr_desc = Pstr_eval (wrap_funs e, attrs) }
        | _ -> item)
      gwt_body
  in
  (match
     ReventlessPpx__SidecarEmit.gwt_fragment_json ~fname:"AddProduct_GWT.res" gwt_body_v12
   with
   | None ->
     Printf.printf "  FAIL(gwt v12): Function$-wrapped callbacks extracted nothing\n";
     exit 1
   | Some j ->
     let s = Yojson.Safe.to_string j in
     let contains hay sub =
       let lh = String.length hay and ls = String.length sub in
       let rec go i = i + ls <= lh && (String.equal (String.sub hay i ls) sub || go (i + 1)) in
       ls = 0 || go 0
     in
     if contains s "\"element\":\"AddProduct\""
        && contains s "\"element\":\"ProductAdded\""
        && contains s "\"element\":\"ProductAlreadyExists\""
     then Printf.printf "  ok(gwt): Function$-wrapped (ReScript v12) extraction\n"
     else (Printf.printf "  FAIL(gwt v12): missing elements in:\n%s\n" s; exit 1));

  (* ── Scenario ids: a marker belongs to the test directly below it ─────── *)
  let id_label = function Some s -> s | None -> "None" in
  let expect_id label got want =
    if got = want then Printf.printf "  ok(gwt): %s\n" label
    else (
      Printf.printf "  FAIL(gwt): %s — got %s, want %s\n" label (id_label got)
        (id_label want);
      exit 1)
  in
  (* Markers on 3 and 7, tests on 4, 8 and 10: the test on 10 has no marker of its
     own, and the one on 7 belongs to the test on 8. *)
  let ids = [ (3, "a"); (7, "b"); (12, "c") ] and tests = [ 4; 8; 10 ] in
  expect_id "marker on 3 → test on 4"
    (ReventlessPpx__SidecarEmit.scenario_id_for 4 ~tests ids) (Some "a");
  expect_id "marker on 7 → test on 8"
    (ReventlessPpx__SidecarEmit.scenario_id_for 8 ~tests ids) (Some "b");
  expect_id "test on 10 inherits nothing"
    (ReventlessPpx__SidecarEmit.scenario_id_for 10 ~tests ids) None;

  (* The same through a file: a form-written test with its marker, a hand-written
     test added below it, and a test marked with the older spelling. The markers
     are read from the file on disk; the AST is parsed from the same lines with
     the comments blanked, so the test locations line up with them. *)
  let lines =
    [ ";; describe \"AddProduct\" (fun () ->";
      "  // scenario-id: 1111";
      "  test \"written by the form\" (fun () ->";
      "    thenEvent (whenCmd (givenEvents [||]) (AddProduct { productId = \"prod-1\" }))";
      "      (ProductAdded { productId = \"prod-1\" }));";
      "  test \"written by hand afterwards\" (fun () ->";
      "    thenEvent (whenCmd (givenEvents [||]) (AddProduct { productId = \"prod-2\" }))";
      "      (ProductAdded { productId = \"prod-2\" }));";
      "  // spec-id: 2222";
      "  test \"marked the older way\" (fun () ->";
      "    thenEvent (whenCmd (givenEvents [||]) (AddProduct { productId = \"prod-3\" }))";
      "      (ProductAdded { productId = \"prod-3\" })))" ]
  in
  let fname = Filename.temp_file "Marker_GWT" ".res" in
  let oc = open_out fname in
  List.iter (fun l -> output_string oc (l ^ "\n")) lines;
  close_out oc;
  (match ReventlessPpx__SidecarEmit.read_scenario_ids fname with
   | [ (2, "1111"); (9, "2222") ] ->
     print_endline "  ok(gwt): both marker spellings are read"
   | other ->
     Printf.printf "  FAIL(gwt): read_scenario_ids got [%s]\n"
       (String.concat "; " (List.map (fun (n, id) -> Printf.sprintf "%d,%s" n id) other));
     exit 1);
  let ocaml_src =
    String.concat "\n"
      (List.map
         (fun l -> if String.length (String.trim l) >= 2
                      && String.sub (String.trim l) 0 2 = "//" then "" else l)
         lines)
  in
  let marker_body = Parse.implementation (Lexing.from_string ocaml_src) in
  let mj =
    match ReventlessPpx__SidecarEmit.gwt_fragment_json ~fname marker_body with
    | Some j -> j
    | None -> (Printf.printf "  FAIL(gwt): marker file extracted nothing\n"; exit 1)
  in
  Sys.remove fname;
  let ids_of key =
    match mj with
    | `Assoc fields -> (
      match List.assoc_opt "scenarios" fields with
      | Some (`List scenarios) ->
        List.map
          (function
            | `Assoc sf -> (
              match List.assoc_opt key sf with Some (`String id) -> id | _ -> "<missing>")
            | _ -> "<missing>")
          scenarios
      | _ -> [])
    | _ -> []
  in
  let show xs = "[" ^ String.concat "; " xs ^ "]" in
  (match (ids_of "scenarioId", ids_of "specId") with
   | ([ "1111"; ""; "2222" ] as a), b when a = b ->
     print_endline
       "  ok(gwt): scenarioId and specId agree; the hand-written test below a marked one has no id"
   | a, b ->
     Printf.printf "  FAIL(gwt): scenarioId %s, specId %s\n" (show a) (show b);
     exit 1);

  (* ── Typed ids: the role follows the type, inside the existing vocabulary ── *)
  let identity_body : structure =
    [%str
      type event =
        | BuyerRegistered of
            { buyer : CustomerId.t
            ; owner : CustomerId.t [@partitionTag]
            ; seller : CustomerId.t [@dcbTag "sellerId"]
            ; wishlist : ProductId.t array }
        [@@schema]]
  in
  let ij =
    ReventlessPpx__SidecarEmit.fragment_json ~spec_name:"RegisterBuyer"
      ~fname:"RegisterBuyer.res" identity_body
  in
  let is = Yojson.Safe.to_string ij in
  let imust label needle =
    let contains hay sub =
      let lh = String.length hay and ls = String.length sub in
      let rec go i = i + ls <= lh && (String.equal (String.sub hay i ls) sub || go (i + 1)) in
      ls = 0 || go 0
    in
    if contains is needle then Printf.printf "  ok(identity): %s\n" label
    else (Printf.printf "  FAIL(identity): %s\n    missing %S in:\n%s\n" label needle is; exit 1)
  in
  imust "auto-tagged by the identity's key"
    "\"name\":\"buyer\",\"kind\":{\"kind\":\"custom\",\"name\":\"CustomerId.t\"}";
  imust "buyer → customerId" "{\"role\":\"customKey\",\"key\":\"customerId\"}";
  imust "partition carries the key" "{\"role\":\"partition\",\"key\":\"customerId\"}";
  imust "an explicit key wins" "{\"role\":\"customKey\",\"key\":\"sellerId\"}";
  imust "array element → productId" "{\"role\":\"customKey\",\"key\":\"productId\"}";

  (* A typed id made from a literal reads as that literal. *)
  (match
     ReventlessPpx__SidecarEmit.example_of_expr [%expr oid "o1"]
   with
   | Some j when Yojson.Safe.to_string j
                 = "{\"kind\":\"string\",\"value\":\"o1\",\"constructor\":\"oid\"}" ->
     print_endline "  ok: a typed id's literal is its example value"
   | other ->
     Printf.printf "  FAIL: typed id example: %s\n"
       (match other with Some j -> Yojson.Safe.to_string j | None -> "None");
     exit 1);

  print_endline "ALL SIDECAR CHECKS PASSED"
