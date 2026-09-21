(* Every lambda the PPX injects must carry its arity: the compiler reads it off a
   [Function$] wrapper with [@res.arity], and from 12.3.1 rejects a bare [Pexp_fun]
   against a spec signature such as [command => permission]. *)

open Ppxlib

let loc = Location.none

let failures = ref 0

let check label (item : structure_item) =
  let arity attrs =
    List.find_map
      (fun a ->
        match (a.attr_name.txt, a.attr_payload) with
        | "res.arity", PStr [ { pstr_desc = Pstr_eval ({ pexp_desc = Pexp_constant (Pconst_integer (n, _)); _ }, _); _ } ] ->
          Some n
        | _ -> None)
      attrs
  in
  match item.pstr_desc with
  | Pstr_value (_, [ { pvb_expr = { pexp_desc = Pexp_construct ({ txt = Lident "Function$"; _ }, Some { pexp_desc = Pexp_fun _; _ }); pexp_attributes; _ }; _ } ])
    when arity pexp_attributes = Some "1" ->
    Printf.printf "  ok: %s\n" label
  | _ ->
    Printf.printf "  FAIL: %s is not Function$(fun …) with @res.arity 1\n" label;
    incr failures

let () =
  let rule = [%expr Reventless.Authorization.AllowAuthenticated] in
  check "commandAuthorization (constant)"
    (ReventlessPpx__AuthorizationInjection.gen_command_authorization ~loc rule);
  check "commandAuthorization (switch)"
    (ReventlessPpx__AuthorizationInjection.gen_command_authorization_switch ~loc
       ~per_constructor_rules:[ ("Add", true, rule) ] ~default_rule:rule ~exhaustive:false);
  check "commandTransition" (ReventlessPpx__AuthorizationInjection.gen_command_transition ~loc);
  if !failures > 0 then exit 1 else print_endline "ALL ARITY CHECKS PASSED"
