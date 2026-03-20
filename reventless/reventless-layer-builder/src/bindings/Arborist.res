type node

type edge

// --- Node accessors ---

@get external name: node => string = "name"
@get external version: node => string = "version"
@get external packageName: node => string = "packageName"
@get external nodePath: node => string = "path"
@get external location: node => string = "location"
@get external resolved: node => string = "resolved"
@get external isRoot: node => bool = "isRoot"
@get external dev: node => bool = "dev"
@get external optional: node => bool = "optional"
@get external devOptional: node => bool = "devOptional"
@get external peer: node => bool = "peer"
@get external nodeType: node => string = "type"
@get external children: node => Map.t<string, node> = "children"
@get external edgesIn: node => Set.t<edge> = "edgesIn"
@get external edgesOut: node => Map.t<string, edge> = "edgesOut"

// --- Edge accessors ---

@get external edgeType: edge => string = "type"
@get external prod: edge => bool = "prod"
@get external edgeName: edge => string = "name"
@get external from: edge => node = "from"

// --- Constructor ---

type t

type config
external makeConfig: dict<string> => config = "%identity"

@new @module("@npmcli/arborist")
external make: config => t = "default"

type buildIdealTreeOptions = {
  preferDedupe?: bool,
  saveType?: string,
}

@send
external buildIdealTree: (t, buildIdealTreeOptions) => promise<node> = "buildIdealTree"

// --- Helpers ---

@val external setToArray: Set.t<'a> => array<'a> = "Array.from"

@send
external mapForEachWithKey: (Map.t<'k, 'v>, ('v, 'k, Map.t<'k, 'v>) => unit) => unit = "forEach"
