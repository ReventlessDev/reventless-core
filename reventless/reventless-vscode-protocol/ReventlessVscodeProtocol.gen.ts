// Hand-written cross-package genType type bridge (NOT generated). When another
// package references this namespaced package's genType types, genType emits an import
// of `@reventlessdev/reventless-vscode-protocol/ReventlessVscodeProtocol.gen` with
// `Protocol_`-prefixed names. genType emits the per-module `src/Protocol.gen.ts` with
// bare names, so this root file bridges the two — re-exporting under the expected
// names. Type-only (erased at runtime); the contract shape stays single-source in
// `src/Protocol.res`.
export type {
  assertionKind as Protocol_assertionKind,
  componentKind as Protocol_componentKind,
  componentMeta as Protocol_componentMeta,
  componentRef as Protocol_componentRef,
  deadCodeFinding as Protocol_deadCodeFinding,
  deadCodeKind as Protocol_deadCodeKind,
  edgeKind as Protocol_edgeKind,
  failLocation as Protocol_failLocation,
  failMessage as Protocol_failMessage,
  graphEdge as Protocol_graphEdge,
  graphNode as Protocol_graphNode,
  itemKind as Protocol_itemKind,
  packageInfo as Protocol_packageInfo,
  position as Protocol_position,
  streamEvent as Protocol_streamEvent,
  vsRange as Protocol_vsRange,
} from './src/Protocol.gen';
export type {
  componentKind as GraphOps_componentKind,
  edgeKind as GraphOps_edgeKind,
  graphEdge as GraphOps_graphEdge,
  graphLeaf as GraphOps_graphLeaf,
  graphNode as GraphOps_graphNode,
  leafGroups as GraphOps_leafGroups,
  readCandidate as GraphOps_readCandidate,
  subgraph as GraphOps_subgraph,
} from './src/GraphOps.gen';
export type {legendEntry as D2Legend_legendEntry} from './src/D2Legend.gen';
export type {
  gEdge as DomainGraphD2_gEdge,
  gNode as DomainGraphD2_gNode,
  subgraph as DomainGraphD2_subgraph,
} from './src/DomainGraphD2.gen';
