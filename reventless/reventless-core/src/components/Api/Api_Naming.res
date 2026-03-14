type queryNames = {
  singleFieldName: string,
  listFieldName: string,
  returnTypeName: string,
  pluralTypeName: string,
}

let pluralize = (n: string) => n->String.endsWith("s") ? n : n ++ "s"

let singularize = (n: string) =>
  if n->String.endsWith("ies") {
    n->String.slice(~start=0, ~end=n->String.length - 3) ++ "y"
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

let queryFieldNamesForReadModel = (~plugin: string, ~name: string): queryNames => {
  let singular = singularize(name)
  let plural = pluralize(name)
  {
    singleFieldName: `${plugin}_${singular}`,
    listFieldName: `${plugin}_${plural}`,
    returnTypeName: `${plugin}_${singular}`,
    pluralTypeName: `${plugin}_${plural}`,
  }
}

let queryFieldNamesForStateView = (~plugin: string, ~viewName: string): queryNames => {
  let entity = stripViewSuffix(viewName)
  let singular = singularize(entity)
  let plural = pluralize(entity)
  {
    singleFieldName: `${plugin}_${singular}`,
    listFieldName: `${plugin}_${plural}`,
    returnTypeName: `${plugin}_${singular}`,
    pluralTypeName: `${plugin}_${plural}`,
  }
}

let queryFieldNamesForSliceQueryDb = (~plugin: string, ~queryDbName: string): queryNames => {
  {
    singleFieldName: `${plugin}_${queryDbName}`,
    listFieldName: `${plugin}_${queryDbName}s`,
    returnTypeName: `${plugin}_${queryDbName}`,
    pluralTypeName: `${plugin}_${queryDbName}s`,
  }
}

let adminField = (~name: string) => `Admin_${name}`
