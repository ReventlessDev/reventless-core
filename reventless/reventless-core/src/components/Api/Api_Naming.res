type queryNames = {
  singleFieldName: string,
  listFieldName: string,
  itemsFieldName?: string,
  returnTypeName: string,
  pluralTypeName: string,
  itemsFilterTypeName?: string,
  connectionFilterTypeName?: string,
  labelField?: string,
  includeIdParam: bool,
  connectionSpec: bool,
}

let pluralize = (n: string) =>
  if RegExp.test(%re("/[^aeiou]y$/i"), n) {
    n->String.slice(~start=0, ~end=String.length(n) - 1) ++ "ies"
  } else if n->String.endsWith("s") || n->String.endsWith("x") || n->String.endsWith("z") || n->String.endsWith("ch") || n->String.endsWith("sh") {
    n ++ "es"
  } else {
    n ++ "s"
  }

let singularize = (n: string) =>
  if n->String.endsWith("ies") {
    n->String.slice(~start=0, ~end=n->String.length - 3) ++ "y"
  } else if n->String.endsWith("ses") || n->String.endsWith("xes") || n->String.endsWith("zes") || n->String.endsWith("ches") || n->String.endsWith("shes") {
    n->String.slice(~start=0, ~end=n->String.length - 2)
  } else if n->String.endsWith("s") {
    n->String.slice(~start=0, ~end=n->String.length - 1)
  } else {
    n
  }

let stripViewSuffix = (n: string) =>
  n->String.endsWith("View") ? n->String.slice(~start=0, ~end=n->String.length - 4) : n

let aggregateMutationField = (~plugin: string, ~aggregate: string, ~command: string) =>
  `${plugin}_${aggregate}_${command}`

let sliceMutationField = (~plugin: string, ~slice: string) => `${plugin}_${slice}`

// DCB StateChangeSlice per-command mutation field. Unlike aggregates — where multiple
// aggregates coexist under a plugin so the aggregate name must namespace the command —
// a DCB slice's command constructor already names the operation, and callers/plans
// treat the mutation as `${plugin}_${command}`. Doubling in the slice name
// (`${plugin}_${slice}_${command}`) both renames the primary command out from under
// existing callers and overflows AppSync's 50-char subscription-field cap once the
// `on` prefix is added.
let dcbCommandMutationField = (~plugin: string, ~command: string) => `${plugin}_${command}`

// AppSync hard limit: subscription field names may be at most 50 chars. Each mutation
// field `f` produces a `@aws_subscribe` subscription `on${f}` (see
// Plugin_SubscriptionSchema.sourceCFields), so the real cap on a mutation field is 48.
// Fail at build with an actionable message rather than letting AppSync reject the
// schema push at deploy time with an opaque 500.
let appSyncSubscriptionMaxLen = 50

let assertSubscriptionNameFits = (~fieldName: string) => {
  let subscriptionName = `on${fieldName}`
  if subscriptionName->String.length > appSyncSubscriptionMaxLen {
    JsError.throwWithMessage(
      `Generated subscription field \`${subscriptionName}\` is ${subscriptionName
        ->String.length
        ->Int.toString} chars, over AppSync's ${appSyncSubscriptionMaxLen->Int.toString}-char limit. ` ++
      `Shorten the plugin, slice, or command name behind mutation field \`${fieldName}\`.`,
    )
  }
  fieldName
}

// DCB StateChangeSlice mutation fields — one per API-exposed command constructor,
// mirroring the aggregate path (which emits one field per constructor). A slice whose
// command union has a single API-exposed constructor keeps the byte-identical
// `Plugin_Slice` name (no schema churn); a multi-command slice names each mutation
// `${plugin}_${command}` — the constructor already names the operation, and callers/plans
// expect that shape (not aggregate-style `${plugin}_${slice}_${command}`). @noApi
// variants are filtered out. Every emitted name is guarded against the 50-char AppSync
// subscription cap at build time. Returns [(fieldName, constructorName)] in declaration order.
let sliceMutationFields = (
  ~plugin: string,
  ~slice: string,
  ~commandSchema: S.t<unknown>,
): array<(string, string)> => {
  let allNames = Reventless.DcbTag.extractAllVariantNames(commandSchema->Obj.magic)
  let filtered = ApiNoApiHelpers.filterNoApiVariants(allNames, commandSchema)
  switch filtered {
  | [] => []
  | [single] => [(assertSubscriptionNameFits(~fieldName=sliceMutationField(~plugin, ~slice)), single)]
  | _ =>
    filtered->Array.map(ctor => (
      assertSubscriptionNameFits(~fieldName=dcbCommandMutationField(~plugin, ~command=ctor)),
      ctor,
    ))
  }
}

// The mutation field name for a single command constructor of a DCB StateChangeSlice,
// consistent with `sliceMutationFields`: single-command slices resolve every variant
// to the slice name, multi-command slices to the per-constructor `${plugin}_${command}`.
let sliceMutationFieldFor = (
  ~plugin: string,
  ~slice: string,
  ~commandSchema: S.t<unknown>,
  ~variant: string,
): string =>
  if sliceMutationFields(~plugin, ~slice, ~commandSchema)->Array.length <= 1 {
    sliceMutationField(~plugin, ~slice)
  } else {
    dcbCommandMutationField(~plugin, ~command=variant)
  }

// Pluralize via the singular stem so already-plural names normalise correctly:
// "Orders" → "Order" → "Orders" (was "Orderses"); "Categories" → "Category" →
// "Categories" (was "Categorieses"). For singular entity names like
// "ProductDemand" the singularize is a no-op and pluralize behaves as usual.
let canonicalPlural = (n: string) => pluralize(singularize(n))

let queryFieldNamesForReadModel = (~plugin: string, ~name: string, ~connectionSpec: bool=true): queryNames => {
  let singular = singularize(name)
  let plural = canonicalPlural(name)
  {
    singleFieldName: `${plugin}_${singular}`,
    listFieldName: `${plugin}_${plural}`,
    returnTypeName: `${plugin}_${singular}`,
    pluralTypeName: `${plugin}_${plural}`,
    includeIdParam: true,
    connectionSpec,
  }
}

let queryFieldNamesForStateView = (~plugin: string, ~viewName: string, ~connectionSpec: bool=true): queryNames => {
  let entity = stripViewSuffix(viewName)
  let singular = singularize(entity)
  let plural = canonicalPlural(entity)
  {
    singleFieldName: `${plugin}_${singular}`,
    listFieldName: `${plugin}_${plural}`,
    returnTypeName: `${plugin}_${singular}`,
    pluralTypeName: `${plugin}_${plural}`,
    includeIdParam: true,
    connectionSpec,
  }
}

// Slice query DBs (AutomationSlice todo, InboundTranslationSlice audit,
// OutboundTranslationSlice todo) all use a string `id` partition key — keep
// `includeIdParam: true` so the SDL single-id query (`Plugin_Foo(id: ID!)`),
// the resolver path (`GetItem` instead of `Scan`), and the `*ByIds` batch
// resolver all line up. StateViewSlice uses `queryFieldNamesForStateView`
// instead and keeps its own (id-free) shape.
let queryFieldNamesForSliceQueryDb = (~plugin: string, ~queryDbName: string, ~connectionSpec: bool=true): queryNames => {
  {
    singleFieldName: `${plugin}_${queryDbName}`,
    listFieldName: `${plugin}_${canonicalPlural(queryDbName)}`,
    returnTypeName: `${plugin}_${queryDbName}`,
    pluralTypeName: `${plugin}_${canonicalPlural(queryDbName)}`,
    includeIdParam: true,
    connectionSpec,
  }
}

let adminField = (~name: string) => `Platform_${name}`
