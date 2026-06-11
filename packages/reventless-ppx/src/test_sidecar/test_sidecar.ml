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
                ProductAlreadyExists))]
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

  (* spec_id_for: nearest preceding comment line wins. *)
  (match
     ReventlessPpx__SidecarEmit.spec_id_for 10 [ (3, "a"); (7, "b"); (12, "c") ]
   with
   | Some "b" -> Printf.printf "  ok(gwt): spec_id_for nearest-preceding\n"
   | other ->
     Printf.printf "  FAIL(gwt): spec_id_for got %s\n"
       (match other with Some s -> s | None -> "None");
     exit 1);

  print_endline "ALL SIDECAR CHECKS PASSED"
