type filterReason =
  | Dev
  | Optional
  | DevOptional
  | Peer
  | ScopeExcluded
  | ModuleExcluded
  | DependentExcluded

let isNodeScopeExcluded = (excludedScopes, node) => {
  let name = node->Arborist.name
  excludedScopes->Array.some(scope => name->String.startsWith("@" ++ scope ++ "/"))
}

let isNodeExcluded = (excludedModules, node) => {
  excludedModules->Array.includes(node->Arborist.name)
}

let hasDependency = (node, dependencyName) => {
  let found = ref(false)
  node->Arborist.edgesOut->Arborist.mapForEachWithKey((_edge, key, _map) => {
    if key === dependencyName {
      found := true
    }
  })
  found.contents
}

let hasRescriptDependency = node => hasDependency(node, "rescript")

let isNecessary = (~excludeScopes, ~excludeModules, ~includeModules=[], node) => {
  if includeModules->Array.includes(node->Arborist.name) {
    None
  } else
  if node->Arborist.dev {
    Some(Dev)
  } else if node->Arborist.optional {
    Some(Optional)
  } else if node->Arborist.devOptional {
    Some(DevOptional)
  } else if node->Arborist.peer {
    Some(Peer)
  } else if isNodeScopeExcluded(excludeScopes, node) {
    Some(ScopeExcluded)
  } else if isNodeExcluded(excludeModules, node) {
    Some(ModuleExcluded)
  } else {
    let tracks = Map.make()
    let _res = Treeverse.depth({
      tree: node,
      visit: n => {
        tracks->Map.delete(n->Arborist.name)->ignore
        isNodeScopeExcluded(excludeScopes, n) || isNodeExcluded(excludeModules, n)
      },
      getChildren: (n, isExcluded) => {
        if !isExcluded {
          let edgesIn = n->Arborist.edgesIn->Arborist.setToArray
          if edgesIn->Array.length > 0 {
            let children =
              edgesIn
              ->Array.filter(e => e->Arborist.prod)
              ->Array.map(e => e->Arborist.from)
            children->Array.forEach(c => tracks->Map.set(c->Arborist.name, c)->ignore)
            children
          } else {
            tracks->Map.set("_reached_top_", Obj.magic(true))->ignore
            []
          }
        } else {
          []
        }
      },
    })
    if tracks->Map.size === 0 {
      Some(DependentExcluded)
    } else {
      None
    }
  }
}

let predIsNecessary = (~excludeScopes, ~excludeModules, ~includeModules=[], node) =>
  isNecessary(~excludeScopes, ~excludeModules, ~includeModules, node)->Option.isNone

let rec filterNodes = (node, ~predicate) => {
  let count = ref(0)
  node->Arborist.children->Arborist.mapForEachWithKey((child, key, map) => {
    if predicate(child) && map->Map.delete(key) {
      count := count.contents + 1 + DependencyBundler_Stats.countChildrenRecursive(child)
    } else if DependencyBundler_Stats.hasChildren(child) {
      count := count.contents + filterNodes(child, ~predicate)
    }
  })
  count.contents
}

let isRescriptModule = node => {
  let path = node->Arborist.nodePath
  NodeFs.existsSync(path ++ "/bsconfig.json") || NodeFs.existsSync(path ++ "/rescript.json")
}
