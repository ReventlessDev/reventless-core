(* Every attribute an author writes that this PPX reads: where it is read, whether
   it takes an argument, and one line on what it does. `reventless-ppx-read
   --vocabulary` prints it; test_vocabulary fails when a module matches a name
   this table does not list, or the table lists one no module matches. Not
   listed: `res.*`, `ocaml.*`, `schema`, `s.*`. See
   docs/plans/attribute-vocabulary-from-the-ppx.md. *)

(* Whose field, case or type: [Other] is any type not named `command`, `event`,
   `consumedEvent` or `state` — a named record, an enum, another variant. *)
type owner = Command | Event | ConsumedEvent | State | Other

type position =
  | File  (* a standalone `@@…` item, at the top of a file or inside a module *)
  | Module  (* a module binding *)
  | Type of owner
  | Case of owner  (* a variant constructor *)
  | Field of owner  (* a record field, or a field of a constructor's inline record *)

type args = No_args | Optional | Required

type entry = {
  name : string;
  positions : position list;
  args : args;
  args_example : string option;
  summary : string;
  replaced_by : string option;
  read_by : string list;
}

let owner_name = function
  | Command -> "command"
  | Event -> "event"
  | ConsumedEvent -> "consumedEvent"
  | State -> "state"
  | Other -> "other"

let position_name = function
  | File -> "file"
  | Module -> "module"
  | Type o -> "type." ^ owner_name o
  | Case o -> "case." ^ owner_name o
  | Field o -> "field." ^ owner_name o

let args_name = function No_args -> "none" | Optional -> "optional" | Required -> "required"

let e ?(args = No_args) ?ex ?replaced_by name positions summary read_by =
  { name; positions; args; args_example = ex; summary; replaced_by; read_by }

(* The fields of a `@schema` variant the DCB passes walk. *)
let dcb_fields = [ Field Command; Field Event; Field ConsumedEvent ]

(* The ungated field passes walk every record and inline record in the file. *)
let any_field = [ Field Command; Field Event; Field ConsumedEvent; Field State; Field Other ]

let state = [ Field State ]

let mode kind summary =
  e ~args:Optional ("reventless." ^ kind) [ File ] summary [ "ReventlessPpx" ]

let all : entry list =
  [ (* ── files and modules ── *)
    e ~args:Optional ~ex:{|"Catalog.Products"|} "reventless.spec" [ File ]
      "Marks a spec file: injects its name, Id and moduleUrl, and runs the field passes."
      [ "ReventlessPpx" ];
    mode "behavior" "Marks a behavior file: opens its spec and injects Spec and moduleUrl.";
    mode "projection" "Marks a state view's projection file: opens its spec and injects Spec and moduleUrl.";
    mode "automation" "Marks an automation file: its process and per-source mappings, with the spec opened.";
    mode "translation" "Marks a translation file: opens its spec and injects Spec and moduleUrl.";
    mode "mappings" "Marks a file of per-source mappings (`_Mappings` or `_Projections`) and injects their functor.";
    mode "extension" "Marks an extension file, and derives the table of events it routes to commands.";
    mode "task" "Marks a task file: injects its name and moduleUrl.";
    e "reventless.dcbTags" [ File ] "Infers DCB tags in a file outside a slice folder."
      [ "ReventlessPpx" ];
    e "reventless.async" [ File ]
      "Dispatches this aggregate's or slice's commands asynchronously: a command answers pending."
      [ "ReventlessPpx" ];
    e "reventless.systemCallable" [ File ]
      "Lets a deploy-time system caller (IAM) call this component's GraphQL fields."
      [ "ReventlessPpx" ];
    e ~args:Optional ~ex:"Product, Product_Behavior" "reventless.gwt" [ File ]
      "Marks a GWT test file: opens its spec and includes the matching test DSL."
      [ "GwtInference" ];
    e ~args:Required ~ex:"Internal" "reventless.visibility" [ File ]
      "Hides a read model or state view from the generated UI (`Internal`); the default is `Public`."
      [ "VisibilityInjection" ];
    e ~args:Required ~ex:{|AllowGroups(["Admin"])|} "reventless.authorize" [ File ]
      "Who may call this component, in place of the default: any signed-in user."
      [ "AuthorizationInjection" ];
    e ~args:Required ~ex:"AlwaysStrong" "reventless.consistency" [ File ]
      "How a state-change slice reads its history before deciding; the default escalates on retry."
      [ "ReadConsistencyInjection" ];
    e ~args:Required ~ex:"50" "reventless.snapshots" [ File ]
      "Snapshots this aggregate's state every N events."
      [ "SnapshotInjection" ];
    e "reventless.examples" [ File ] "Marks a module of named example values that scenarios refer to."
      [ "SidecarEmit" ];
    e "reventless.delegate" [ Module ]
      "Treats this module as a Delegate outside an extension-point or extension file."
      [ "ReventlessPpx" ];
    e ~replaced_by:"reventless.mappings" "reventless.projections" []
      "Removed. Move the mappings into a `_Projections.res` file marked `@@reventless.mappings`."
      [ "ReventlessPpx" ];
    (* ── types and cases ── *)
    e "noApi" [ Type Command; Case Command ]
      "Keeps this command, or every command of the type, off the GraphQL and MCP APIs."
      [ "NoApiAnnotation"; "ReventlessPpx" ];
    e ~args:Required ~ex:{|AllowGroups(["Admin"])|} "authorize" [ Case Command ]
      "Who may issue this one command, in place of the file's rule."
      [ "AuthorizationInjection" ];
    e ~args:Required ~ex:"false" "live" [ Type State ] "Whether the view offers live updates by default."
      [ "StateAnnotations" ];
    e "namedWhenRetired" [ Type State ]
      "A retired row still answers the reference door with its name."
      [ "StateAnnotations" ];
    e "transition" [] "Removed. Declare the command's edge in a `commandTransition` switch."
      [ "TransitionAnnotation" ];
    e "allowedStates" [] "Removed. Declare the from-set in a `commandTransition` switch."
      [ "TransitionAnnotation" ];
    e "targetState" [] "Removed. Declare the target in a `commandTransition` switch."
      [ "TransitionAnnotation" ];
    (* ── DCB tags ── *)
    e "partitionTag" dcb_fields
      "The id this event is stored under, where the slice's partition cannot be inferred."
      [ "DcbTagInference"; "SidecarEmit" ];
    e "crossPartition" dcb_fields "A tag whose decision read spans every partition carrying it."
      [ "DcbTagInference" ];
    e ~args:Optional ~ex:{|"sku"|} "dcbTag" dcb_fields
      "Tags a field that is not named `*Id`; the argument sets the tag key."
      [ "DcbTagInference"; "SidecarEmit" ];
    e ~args:Optional ~ex:{|"/"|} "compositePartitionTag" dcb_fields
      "One segment of a partition key made of several fields, joined in declaration order."
      [ "DcbTagInference"; "SidecarEmit" ];
    e "noDcbTag" any_field "This `*Id` field is payload, not a DCB tag."
      [ "DcbTagInference"; "ReferenceInference"; "SidecarEmit" ];
    e ~replaced_by:"noDcbTag" "noTag" [] "Renamed. Use `@noDcbTag`." [ "DcbTagInference" ];
    (* ── any field ── *)
    e ~args:Required ~ex:{|"Catalog.Product"|} "ref" any_field "This field holds the id of another entity."
      [ "ReferenceInference" ];
    e ~args:Required ~ex:{|"Catalog.productImages"|} "storageRef" any_field
      "The object store the file this field refers to is kept in."
      [ "StorageRefInference"; "UploadableInference" ];
    e ~args:Required ~ex:{|"pluginStructures"|} "offload" any_field
      "A value kept in an object store and carried by reference when large, inline when small."
      [ "OffloadInference" ];
    e ~args:Optional ~ex:"{index: false}" "owner" any_field
      "The caller a row or command belongs to: set from the caller on write, and narrowing reads."
      [ "OwnerInference"; "StateAnnotations" ];
    e "sensitive" any_field "A value that must not be put into content a person receives."
      [ "SensitiveInference" ];
    e ~args:Required ~ex:"1" "default" any_field "The value a generated form opens this field on."
      [ "DefaultInference" ];
    (* ── state fields ── *)
    e ~args:Optional ~ex:{|" "|} "displayName" state
      "Part of the row's display name, with the other fields marked; the argument is the separator."
      [ "DisplayNameInference" ];
    e "id" state "The row's partition key."
      [ "StateAnnotations"; "TaggedUnionInference"; "SidecarEmit" ];
    e ~args:Optional ~ex:{|"/"|} "compositeId" state
      "One segment of a partition key made of several fields; the argument is the separator."
      [ "StateAnnotations"; "TaggedUnionInference"; "SidecarEmit" ];
    e "subId" state "The row's sort key." [ "StateAnnotations"; "TaggedUnionInference" ];
    e ~args:Optional ~ex:{|"/"|} "compositeSubId" state
      "One segment of a sort key made of several fields; the argument is the separator."
      [ "StateAnnotations"; "TaggedUnionInference"; "SidecarEmit" ];
    e ~args:Optional ~ex:{|"byCustomer"|} "index" state
      "A key of a secondary index; the argument names it, or sets its projection."
      [ "StateAnnotations"; "TaggedUnionInference"; "SidecarEmit" ];
    e ~args:Required ~ex:{|"byCustomer"|} "indexSubId" state "The sort key of the named secondary index."
      [ "StateAnnotations"; "TaggedUnionInference" ];
    e ~args:Required ~ex:{|{table: "Products", field: "product"}|} "resolves" state
      "Adds a field resolving this id to a row of another view of the plugin."
      [ "StateAnnotations" ];
    e ~args:Required ~ex:{|{table: "Products", field: "products"}|} "resolvesMany" state
      "Adds a field resolving these ids to rows of another view of the plugin."
      [ "StateAnnotations" ];
    e "lifecycle" state "The field a record's lifecycle lives in."
      [ "StateAnnotations"; "TaggedUnionInference" ];
    e ~replaced_by:"lifecycle" "status" [] "Renamed. Use `@lifecycle`." [ "StateAnnotations" ];
    e "groupBy" state "The field a list view sections its rows by."
      [ "StateAnnotations"; "TaggedUnionInference" ];
    e ~args:Optional ~ex:{|"Archived"|} "retired" [ Field State; Case Other ]
      "The flag, or the lifecycle state, that withdraws a row from ordinary reads."
      [ "StateAnnotations"; "TaggedUnionInference" ];
    e "hidden" state "Left out of summary and list views." [ "StateAnnotations" ];
    e "summary" state "Always shown in summary and list views." [ "StateAnnotations" ];
    e "internal" state "Left out of the generated GraphQL type; still stored." [ "StateAnnotations" ];
    e ~args:Required ~ex:{|"OrderLines"|} "drillTarget" state "The view a row drills down into."
      [ "StateAnnotations" ];
    e "collapsed" state "Shown collapsed in a hierarchical view." [ "StateAnnotations" ];
    e "scan" state "Lets a field without an index be filtered on the server."
      [ "StateAnnotations"; "TaggedUnionInference" ];
    e "scanSort" state "Lets a field without an index be sorted on the server."
      [ "StateAnnotations"; "TaggedUnionInference" ];
    e ~args:Required ~ex:{|"currency"|} "semantic" state "What the value means, for how it is shown."
      [ "StateAnnotations" ];
    e ~args:Required ~ex:{|"sum"|} "metric" state "A dashboard metric over this field."
      [ "StateAnnotations" ] ]

let entry_json (x : entry) : Yojson.Safe.t =
  let opt k = function Some v -> [ (k, `String v) ] | None -> [] in
  `Assoc
    ([ ("name", `String x.name);
       ("positions", `List (List.map (fun p -> `String (position_name p)) x.positions));
       ("args", `String (args_name x.args)) ]
    @ opt "argsExample" x.args_example
    @ [ ("summary", `String x.summary) ]
    @ opt "replacedBy" x.replaced_by
    @ [ ("readBy", `List (List.map (fun m -> `String m) x.read_by)) ])

let to_json ~(version : string option) : Yojson.Safe.t =
  `Assoc
    [ ("version", match version with Some v -> `String v | None -> `Null);
      ("attributes", `List (List.map entry_json all)) ]
