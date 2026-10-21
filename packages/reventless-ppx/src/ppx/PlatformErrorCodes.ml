open Ppxlib

(** A spec's [type error] may not name a variant like a code the platform puts
    on a rejected command, so [errorCode] never means both the model's reason
    and the platform's.

    A copy of [Reventless.CommandOutcome.platformErrorCodes]: the PPX cannot read
    ReScript, and a spec test keeps the two lists equal. *)
let platform_error_codes = [
  "Forbidden"; "Conflict"; "AppendFailed"; "PluginUnavailable"; "PluginInactive";
  "PluginRetired"; "PublishFailed"; "TranslationFailed" ]

let check_error_type (td : type_declaration) =
  match td.ptype_name.txt, td.ptype_kind with
  | "error", Ptype_variant constructors ->
    List.iter (fun (cd : constructor_declaration) ->
      if List.mem cd.pcd_name.txt platform_error_codes then
        Location.raise_errorf ~loc:cd.pcd_loc
          "[reventless-ppx] `%s` is a code the platform uses for its own rejections; \
           name this error for what the model means, such as `AlreadyBooked`"
          cd.pcd_name.txt
    ) constructors
  | _ -> ()

(** Refuses a reserved name in any [type error] of the structure, nested modules
    included. Run on spec and decision files. *)
let rec check_structure (str : structure) =
  List.iter (fun (item : structure_item) ->
    match item.pstr_desc with
    | Pstr_type (_, decls) -> List.iter check_error_type decls
    | Pstr_module { pmb_expr = { pmod_desc = Pmod_structure inner; _ }; _ } ->
      check_structure inner
    | _ -> ()
  ) str
