// The Node runtime every deployed function runs on, and the runtimes the shared
// layer is published for. No imports, so a deploy script can read it without
// loading Pulumi. The layer keeps the previous runtime listed while functions
// still on it are moved over.
let node = "nodejs24.x"

let layerCompatible = ["nodejs22.x", node]
