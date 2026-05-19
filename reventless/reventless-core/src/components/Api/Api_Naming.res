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
