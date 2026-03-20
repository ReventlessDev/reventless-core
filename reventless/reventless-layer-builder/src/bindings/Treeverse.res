type depthOptions<'node, 'result> = {
  tree: 'node,
  visit: 'node => 'result,
  getChildren: ('node, 'result) => array<'node>,
  filter?: 'node => bool,
}

@module("treeverse")
external depth: depthOptions<'node, 'result> => 'result = "depth"
