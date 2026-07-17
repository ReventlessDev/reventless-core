let rec maxDepth = (node, ~currentDepth=1) => {
  let children = node->Arborist.children
  if children->Map.size > 0 {
    let localMax = ref(0)
    children->Map.forEach(child => {
      let childMaxDepth = maxDepth(child, ~currentDepth=currentDepth + 1)
      if childMaxDepth > localMax.contents {
        localMax := childMaxDepth
      }
    })
    localMax.contents
  } else {
    currentDepth
  }
}

let rec countChildrenRecursive = node => {
  let children = node->Arborist.children
  if children->Map.size == 0 {
    0
  } else {
    let count = ref(children->Map.size)
    children->Map.forEach(child => {
      count := count.contents + countChildrenRecursive(child)
    })
    count.contents
  }
}

let hasChildren = node => {
  node->Arborist.children->Map.size > 0
}

type stats = {
  allNodesCount: int,
  childNodesCount: int,
  diffCount: int,
  maxDepth: int,
}

let stats = (node, ~shouldPrint=false) => {
  let allNodesCount = countChildrenRecursive(node)
  let childNodesCount = node->Arborist.children->Map.size
  let result = {
    allNodesCount,
    childNodesCount,
    diffCount: allNodesCount - childNodesCount,
    maxDepth: maxDepth(node),
  }

  if shouldPrint {
    Console.log("")
    Console.log("---------")
    Console.log("--STATS--")
    Console.log("--" ++ node->Arborist.name)
    Console.log("---------")
    Console.log2("total nodes:", result.allNodesCount)
    Console.log2("children:", result.childNodesCount)
    Console.log2("nested nodes:", result.diffCount)
    Console.log2("maxDepth:", result.maxDepth)
    Console.log("------")
    Console.log("")
  }

  result
}
