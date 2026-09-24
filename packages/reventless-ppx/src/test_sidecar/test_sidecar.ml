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
  if Yojson.Safe.Util.(ij |> member "types" |> to_list |> List.hd |> member "elements"
                       |> to_list |> List.hd |> member "fields" |> to_list
                       |> List.for_all (fun f -> member "ref" f = `Null))
  then print_endline "  ok(identity): a field without @ref has no ref key"
  else (print_endline "  FAIL(identity): a ref key without @ref"; exit 1);

  (* A record a command or event holds is nested: its @ref fields are the
     decision's tags (DcbTag.nestedRecordTags); its other fields are not,
     because only ReferenceInference tags a record's fields. *)
  let nested_body : structure =
    [%str
      type lineItem =
        { productId : CatalogSpec.ProductId.t [@ref "AvailableProducts"]
        ; vendorRef : string [@ref "Catalog.Vendor"] [@noDcbTag]
        ; bundleIds : string array [@ref "Bundle"]
        ; quantity : int }
      [@@schema]

      type orderLine = { productId : CatalogSpec.ProductId.t; name : string } [@@schema]

      type note = { authorId : AuthorId.t [@ref "Author"] } [@@schema]

      type command =
        | PlaceOrder of { orderId : OrderId.t; lineItems : lineItem array }
      [@@schema]

      type event =
        | OrderPlaced of { orderId : OrderId.t; lines : orderLine array option }
      [@@schema]

      type state = { notes : note array } [@@schema]]
  in
  let nj =
    ReventlessPpx__SidecarEmit.fragment_json ~spec_name:"PlaceOrder" ~fname:"PlaceOrder.res"
      nested_body
  in
  let field_of type_name field_name =
    let open Yojson.Safe.Util in
    nj |> member "types" |> to_list
    |> List.find (fun t -> member "typeName" t = `String type_name)
    |> member "elements" |> to_list |> List.hd |> member "fields" |> to_list
    |> List.find (fun f -> member "name" f = `String field_name)
  in
  let nmust label type_name field_name key expected =
    let got = Yojson.Safe.to_string (Yojson.Safe.Util.member key (field_of type_name field_name)) in
    if String.equal got expected then Printf.printf "  ok(nested): %s\n" label
    else (Printf.printf "  FAIL(nested): %s\n    %s.%s %s = %s, expected %s\n" label type_name
            field_name key got expected; exit 1)
  in
  nmust "a nested typed-id @ref is tagged by its identity" "lineItem" "productId" "dcbRole"
    "{\"role\":\"customKey\",\"key\":\"productId\"}";
  nmust "its target" "lineItem" "productId" "ref"
    "{\"entity\":\"AvailableProducts\",\"plugin\":null}";
  nmust "a nested @ref with @noDcbTag is suppressed" "lineItem" "vendorRef" "dcbRole"
    "{\"role\":\"suppressed\"}";
  nmust "a plugin target" "lineItem" "vendorRef" "ref"
    "{\"entity\":\"Vendor\",\"plugin\":\"Catalog\"}";
  nmust "a nested *Ids @ref takes the singular key" "lineItem" "bundleIds" "dcbRole"
    "{\"role\":\"customKey\",\"key\":\"bundleId\"}";
  nmust "a nested plain field is not a tag" "lineItem" "quantity" "dcbRole"
    "{\"role\":\"noTag\"}";
  nmust "a nested typed id without @ref is not a tag" "orderLine" "productId" "dcbRole"
    "{\"role\":\"noTag\"}";
  nmust "a record held only by state is not nested" "note" "authorId" "dcbRole"
    "{\"role\":\"noTag\"}";
  nmust "its target is still recorded" "note" "authorId" "ref"
    "{\"entity\":\"Author\",\"plugin\":null}";
  nmust "top-level fields keep their rules" "command" "orderId" "dcbRole"
    "{\"role\":\"customKey\",\"key\":\"orderId\"}";

  (* ── Annotation arguments ────────────────────────────────────────────────
     Parsed from OCaml-syntax source, then given the columns the ReScript
     parser counts (UTF-16 units from the line's byte start), so the field after
     the `—` is cut the way it would be from a .res file. *)
  let args_src =
    String.concat "\n"
      [ "type command =";
        "  | StockShelf of";
        "      { shelfId : string [@partitionTag]";
        "      ; imageRef : string [@storageRef \"Catalog.images\"]";
        "      ; groups : string [@authorize AllowGroups [\"Admin\", \"Merchandiser\"]]";
        "      ; quantity : int [@default 1]";
        "      ; (* — restocked *) facings : int [@default 2]";
        "      ; note : string [@res.optional] [@res.doc \" a note \"]";
        "      ; shape : string [@shape: int] }";
        "  [@@schema]" ]
  in
  let as_rescript_columns =
    object
      inherit Ast_traverse.map
      method! position (p : Lexing.position) =
        let rec units i n =
          if i >= p.pos_cnum then n
          else
            let c = Char.code args_src.[i] in
            if c < 0x80 then units (i + 1) (n + 1)
            else if c < 0xE0 then units (i + 2) (n + 1)
            else if c < 0xF0 then units (i + 3) (n + 1)
            else units (i + 4) (n + 2)
        in
        if p.pos_bol < 0 || p.pos_cnum < p.pos_bol then p
        else { p with pos_cnum = p.pos_bol + units p.pos_bol 0 }
    end
  in
  let args_body =
    as_rescript_columns#structure (Parse.implementation (Lexing.from_string args_src))
  in
  let annotations ?src () =
    let open Yojson.Safe.Util in
    ReventlessPpx__SidecarEmit.fragment_json ?src ~spec_name:"StockShelf" ~fname:"StockShelf.res"
      args_body
    |> member "types" |> to_list |> List.hd |> member "elements" |> to_list |> List.hd
    |> member "fields" |> to_list
    |> List.map (fun f -> (to_string (member "name" f), Yojson.Safe.to_string (member "annotations" f)))
  in
  let amust label got field expected =
    match List.assoc_opt field got with
    | Some s when String.equal s expected -> Printf.printf "  ok(args): %s\n" label
    | other ->
      Printf.printf "  FAIL(args): %s\n    %s annotations = %s, expected %s\n" label field
        (Option.value other ~default:"<no field>") expected;
      exit 1
  in
  let with_src = annotations ~src:args_src () in
  amust "a bare annotation is its name" with_src "shelfId" "[\"partitionTag\"]";
  amust "an argument is kept, quotes and all" with_src "imageRef"
    "[{\"name\":\"storageRef\",\"args\":\"\\\"Catalog.images\\\"\"}]";
  amust "an argument with spaces, brackets and commas round-trips" with_src "groups"
    "[{\"name\":\"authorize\",\"args\":\"AllowGroups [\\\"Admin\\\", \\\"Merchandiser\\\"]\"}]";
  amust "@default(1)" with_src "quantity" "[{\"name\":\"default\",\"args\":\"1\"}]";
  amust "a field after non-ASCII text on its line" with_src "facings"
    "[{\"name\":\"default\",\"args\":\"2\"}]";
  amust "res.* stay names" with_src "note" "[\"res.optional\",\"res.doc\"]";
  amust "a non-structure payload is a name" with_src "shape" "[\"shape\"]";
  let without = annotations () in
  List.iter
    (fun (field, expected) -> amust ("without the source, " ^ field ^ " is names") without field expected)
    [ ("imageRef", "[\"storageRef\"]"); ("groups", "[\"authorize\"]"); ("quantity", "[\"default\"]");
      ("note", "[\"res.optional\",\"res.doc\"]") ];

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

  (* ── Named values and code (R1) ─────────────────────────────────────────
     `src` stands for the .res file the expressions were parsed from. The ASTs
     are built in OCaml syntax, so an expression recorded as code is given the
     location of its ReScript spelling in `src`, as the ReScript parser would. *)
  let expect_json label got want =
    let show = function Some j -> Yojson.Safe.to_string j | None -> "None" in
    if show got = want then Printf.printf "  ok(values): %s\n" label
    else (
      Printf.printf "  FAIL(values): %s\n    got  %s\n    want %s\n" label (show got) want;
      exit 1)
  in
  let money_text = "Reventless.Money.make(~amount=1000.0, ~currency=Reventless.Currency.EUR)" in
  let src = "let price = " ^ money_text ^ "\n" in
  let located (text : string) (e : expression) : expression =
    let rec find i =
      if String.sub src i (String.length text) = text then i else find (i + 1)
    in
    let a = find 0 in
    let pos c = { Lexing.pos_fname = "Values.res"; pos_lnum = 1; pos_bol = 0; pos_cnum = c } in
    { e with
      pexp_loc =
        { loc_start = pos a; loc_end = pos (a + String.length text); loc_ghost = false } }
  in
  let money =
    located money_text
      [%expr Reventless.Money.make ~amount:1000.0 ~currency:Reventless.Currency.EUR]
  in
  let example = ReventlessPpx__SidecarEmit.example_of_expr ~src in
  expect_json "a bare name is a ref" (example [%expr o1])
    "{\"kind\":\"ref\",\"name\":\"o1\"}";
  expect_json "a qualified name is a ref" (example [%expr OrderingExamples.dockLine])
    "{\"kind\":\"ref\",\"name\":\"OrderingExamples.dockLine\"}";
  expect_json "Some(name) is the name's ref" (example [%expr Some o1])
    "{\"kind\":\"ref\",\"name\":\"o1\"}";
  expect_json "an array of names is a list of refs"
    (example [%expr [| dockLine; OrderingExamples.chargerLine |]])
    "{\"kind\":\"list\",\"items\":[{\"kind\":\"ref\",\"name\":\"dockLine\"},\
     {\"kind\":\"ref\",\"name\":\"OrderingExamples.chargerLine\"}]}";
  expect_json "a record field holding a name is a ref"
    (example [%expr { orderId = o1; quantity = 2 }])
    "{\"kind\":\"record\",\"entries\":[[\"orderId\",{\"kind\":\"ref\",\"name\":\"o1\"}],\
     [\"quantity\",{\"kind\":\"int\",\"value\":2}]]}";
  expect_json "a call is code, as written" (example money)
    (Printf.sprintf "{\"kind\":\"code\",\"value\":%S}" money_text);
  expect_json "a record field holding a call is kept, as code"
    (example
       { ([%expr { name = "Dock"; unitPrice = x }]) with
         pexp_desc =
           Pexp_record
             ( [ ({ txt = Lident "name"; loc }, [%expr "Dock"]);
                 ({ txt = Lident "unitPrice"; loc }, money) ],
               None ) })
    (Printf.sprintf
       "{\"kind\":\"record\",\"entries\":[[\"name\",{\"kind\":\"string\",\"value\":\"Dock\"}],\
        [\"unitPrice\",{\"kind\":\"code\",\"value\":%S}]]}"
       money_text);
  expect_json "Some(call) is the call's code" (example [%expr Some [%e money]])
    (Printf.sprintf "{\"kind\":\"code\",\"value\":%S}" money_text);
  (* No source, or a location the parser did not set: dropped, as before. *)
  expect_json "a call without its source is dropped"
    (ReventlessPpx__SidecarEmit.example_of_expr money) "None";
  expect_json "a call with no location is dropped"
    (example [%expr eur 4500.0]) "None";
  (* The literal cases read as they did, source or no source. *)
  List.iter
    (fun (label, e, want) ->
      expect_json (label ^ " (with source)") (example e) want;
      expect_json (label ^ " (without)") (ReventlessPpx__SidecarEmit.example_of_expr e) want)
    [ ("string", [%expr "p1"], "{\"kind\":\"string\",\"value\":\"p1\"}");
      ("int", [%expr 3], "{\"kind\":\"int\",\"value\":3}");
      ("float", [%expr 9.99], "{\"kind\":\"float\",\"value\":9.99}");
      ("bool", [%expr true], "{\"kind\":\"bool\",\"value\":true}");
      ("None", [%expr None], "{\"kind\":\"null\"}");
      ("Some literal", [%expr Some "x"], "{\"kind\":\"string\",\"value\":\"x\"}");
      ("enum", [%expr Customers.Active], "{\"kind\":\"enum\",\"value\":\"Customers.Active\"}");
      ( "typed id",
        [%expr oid "o1"],
        "{\"kind\":\"string\",\"value\":\"o1\",\"constructor\":\"oid\"}" );
      ( "record of literals",
        [%expr { productId = "p1"; quantity = 1 }],
        "{\"kind\":\"record\",\"entries\":[[\"productId\",{\"kind\":\"string\",\"value\":\"p1\"}],\
         [\"quantity\",{\"kind\":\"int\",\"value\":1}]]}" ) ];

  (* The same through a file: the GWT walk reads the source once and cuts each
     code value from it. The file is in OCaml syntax here, so the text is too. *)
  let gwt_lines =
    [ ";; describe \"Lines\" (fun () ->";
      "  test \"keeps named values and code\" (fun () ->";
      "    thenState (givenEvents [||])";
      "      { lines = [| dockLine; chargerLine |]; total = eur 4500.0; orderId = Some o1 }))" ]
  in
  let gwt_fname = Filename.temp_file "Lines_GWT" ".res" in
  let oc = open_out gwt_fname in
  output_string oc (String.concat "\n" gwt_lines);
  close_out oc;
  let gwt_ast = Parse.implementation (Lexing.from_string (String.concat "\n" gwt_lines)) in
  let lj =
    match ReventlessPpx__SidecarEmit.gwt_fragment_json ~fname:gwt_fname gwt_ast with
    | Some j -> Yojson.Safe.to_string j
    | None -> (Printf.printf "  FAIL(values): the GWT file extracted nothing\n"; exit 1)
  in
  Sys.remove gwt_fname;
  let lmust label needle =
    let contains hay sub =
      let lh = String.length hay and ls = String.length sub in
      let rec go i = i + ls <= lh && (String.equal (String.sub hay i ls) sub || go (i + 1)) in
      ls = 0 || go 0
    in
    if contains lj needle then Printf.printf "  ok(values): %s\n" label
    else (Printf.printf "  FAIL(values): %s\n    missing %S in:\n%s\n" label needle lj; exit 1)
  in
  lmust "a list of named lines is two refs"
    "[\"lines\",{\"kind\":\"list\",\"items\":[{\"kind\":\"ref\",\"name\":\"dockLine\"},\
     {\"kind\":\"ref\",\"name\":\"chargerLine\"}]}]";
  lmust "a helper call is code, cut from the file"
    "[\"total\",{\"kind\":\"code\",\"value\":\"eur 4500.0\"}]";
  lmust "Some(name) is a ref" "[\"orderId\",{\"kind\":\"ref\",\"name\":\"o1\"}]";

  (* ── The example-file sidecar (R2) ────────────────────────────────────── *)
  let ex_lines =
    [ "[@@@reventless.examples]";
      "type orderLine = { name : string; quantity : int }";
      "let dockLine : orderLine = { name = \"Fathom Dock\"; quantity = 1 }";
      "let o1 = OrderId.make \"o1\"";
      "let firstLine = dockLine";
      "let (a, b) = (1, 2)";
      ";; print_endline \"not an example\"";
      "let total : Money.t = eur 4500.0" ]
  in
  let ex_fname = Filename.temp_file "OrderingExamples" ".res" in
  let oc = open_out ex_fname in
  output_string oc (String.concat "\n" ex_lines);
  close_out oc;
  let ex_ast = Parse.implementation (Lexing.from_string (String.concat "\n" ex_lines)) in
  let xj = ReventlessPpx__SidecarEmit.examples_fragment_json ~fname:ex_fname ex_ast in
  Sys.remove ex_fname;
  let field k = function `Assoc fs -> List.assoc_opt k fs | _ -> None in
  let examples =
    match field "examples" xj with Some (`List xs) -> xs | _ -> []
  in
  let show_entry j = Yojson.Safe.to_string j in
  let expect_entry label name want =
    match
      List.find_opt (fun j -> field "name" j = Some (`String name)) examples
    with
    | Some j when show_entry j = want -> Printf.printf "  ok(examples): %s\n" label
    | Some j ->
      Printf.printf "  FAIL(examples): %s\n    got  %s\n    want %s\n" label (show_entry j) want;
      exit 1
    | None -> Printf.printf "  FAIL(examples): %s — no entry %s\n" label name; exit 1
  in
  (match field "module" xj with
   | Some (`String m) when m = Filename.chop_suffix (Filename.basename ex_fname) ".res" ->
     print_endline "  ok(examples): module is the file stem"
   | _ -> print_endline "  FAIL(examples): module"; exit 1);
  expect_entry "an annotated let" "dockLine"
    "{\"name\":\"dockLine\",\"type\":\"orderLine\",\
     \"kind\":{\"kind\":\"custom\",\"name\":\"orderLine\"},\"line\":3,\
     \"value\":{\"kind\":\"record\",\"entries\":[[\"name\",{\"kind\":\"string\",\"value\":\"Fathom Dock\"}],\
     [\"quantity\",{\"kind\":\"int\",\"value\":1}]]}}";
  expect_entry "an unannotated let" "o1"
    "{\"name\":\"o1\",\"type\":\"\",\"kind\":{\"kind\":\"custom\",\"name\":\"Unknown\"},\"line\":4,\
     \"value\":{\"kind\":\"string\",\"value\":\"o1\",\"constructor\":\"OrderId.make\"}}";
  expect_entry "a let whose value is a ref" "firstLine"
    "{\"name\":\"firstLine\",\"type\":\"\",\"kind\":{\"kind\":\"custom\",\"name\":\"Unknown\"},\
     \"line\":5,\"value\":{\"kind\":\"ref\",\"name\":\"dockLine\"}}";
  expect_entry "a let whose value is code" "total"
    "{\"name\":\"total\",\"type\":\"Money.t\",\"kind\":{\"kind\":\"custom\",\"name\":\"Money.t\"},\
     \"line\":8,\"value\":{\"kind\":\"code\",\"value\":\"eur 4500.0\"}}";
  (match List.map (fun j -> field "name" j) examples with
   | [ Some (`String "dockLine"); Some (`String "o1"); Some (`String "firstLine");
       Some (`String "total") ] ->
     print_endline "  ok(examples): the type, the destructuring let and the expression are ignored"
   | _ ->
     Printf.printf "  FAIL(examples): unexpected entries %s\n" (Yojson.Safe.to_string xj);
     exit 1);

  (* ── The shared-types sidecar ─────────────────────────────────────────── *)
  (* Driven through the dispatcher, as the compiler would: whether a module is
     selected is the dispatcher's rule, not SidecarEmit's. *)
  let dir = Filename.temp_dir "types_sidecar" "" in
  (* A spec's moduleUrl is resolved against the package it sits in. *)
  let oc = open_out (Filename.concat dir "package.json") in
  output_string oc "{\"name\": \"shop\"}";
  close_out oc;
  let compile name lines =
    let path = Filename.concat dir name in
    let src = String.concat "\n" lines in
    let oc = open_out path in
    output_string oc src;
    close_out oc;
    let lexbuf = Lexing.from_string src in
    Lexing.set_filename lexbuf path;
    let ast = Parse.implementation lexbuf in
    Format.asprintf "%a" Pprintast.structure (ReventlessPpx.transform ast)
  in
  let sidecar name =
    Filename.concat dir (Filename.chop_suffix name ".res" ^ ".types.json")
  in
  let tmust label cond =
    if cond then Printf.printf "  ok(types): %s\n" label
    else (Printf.printf "  FAIL(types): %s\n" label; exit 1)
  in
  let delivery =
    [ "type t = Standard | Express | Pickup of { storeId : string } [@@schema]" ]
  in
  let address = [ "type t = { street : string; city : string option } [@@schema]" ] in
  let pair =
    [ "type side = Left | Right [@@schema]";
      "type t = { left : side; right : side } [@@schema]";
      "type internal = int" ]
  in
  let unset_output = compile "DeliveryOption.res" delivery in
  tmust "nothing is written without REVENTLESS_EMIT_SIDECAR"
    (not (Sys.file_exists (sidecar "DeliveryOption.res")));
  Unix.putenv "REVENTLESS_EMIT_SIDECAR" "1";
  let set_output = compile "DeliveryOption.res" delivery in
  tmust "the compiled output is the same with the variable set and unset"
    (String.equal unset_output set_output);
  let read name = Yojson.Safe.from_file (sidecar name) in
  let types_of j = match field "types" j with Some (`List ts) -> ts | _ -> [] in
  let dj = read "DeliveryOption.res" in
  tmust "module is the file stem" (field "module" dj = Some (`String "DeliveryOption"));
  (match types_of dj with
   | [ t ] ->
     tmust "one variant entry t"
       (field "typeName" t = Some (`String "t") && field "shape" t = Some (`String "variant"));
     let elements = match field "elements" t with Some (`List es) -> es | _ -> [] in
     tmust "payloadless constructors are payloadless"
       (List.filter_map (fun e -> match field "payloadless" e with
          | Some (`Bool true) -> field "name" e | _ -> None) elements
        = [ `String "Standard"; `String "Express" ]);
     let pickup = List.find (fun e -> field "name" e = Some (`String "Pickup")) elements in
     tmust "the inline-record payload carries its fields"
       (match field "fields" pickup with
        | Some (`List [ f ]) -> field "name" f = Some (`String "storeId")
        | _ -> false)
   | _ -> tmust "exactly one type" false);
  ignore (compile "Address.res" address);
  (match types_of (read "Address.res") with
   | [ t ] -> tmust "a record is shape record" (field "shape" t = Some (`String "record"))
   | _ -> tmust "exactly one record type" false);
  ignore (compile "Pair.res" pair);
  tmust "every @schema type is recorded, and nothing else"
    (List.map (field "typeName") (types_of (read "Pair.res"))
     = [ Some (`String "side"); Some (`String "t") ]);
  List.iter
    (fun (label, name, lines) ->
      ignore (compile name lines);
      tmust label (not (Sys.file_exists (sidecar name))))
    [ ("no sidecar for an identity module", "CustomerId.res",
       [ "include Reventless.Id.Make (struct let name = \"customer\" end)" ]);
      ("no sidecar for a module without a @schema type", "Helpers.res",
       [ "type t = int"; "let double x = x * 2" ]);
      ("no sidecar for a spec", "RegisterOrder.res",
       [ "[@@@reventless.spec]"; "type command = Register [@@schema]" ]);
      ("no sidecar for a behavior file", "RegisterOrder_Behavior.res",
       [ "[@@@reventless.behavior]"; "type step = One [@@schema]" ]);
      ("no sidecar for a GWT file", "RegisterOrder_GWT.res",
       [ "type fixture = A [@@schema]" ]);
      ("no sidecar for an examples file", "OrderingExamples.res",
       [ "[@@@reventless.examples]"; "type line = { n : int } [@@schema]" ]) ];
  ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir)));

  print_endline "ALL SIDECAR CHECKS PASSED"
