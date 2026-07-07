// Hand-written IN-PACKAGE genType type bridge (NOT generated — un-ignored in
// .gitignore). When one module of this namespaced package references another's
// genType types (e.g. GraphOps.res aliasing Protocol.graphNode), genType emits an
// import of './ReventlessVscodeProtocol.gen' RELATIVE TO src/ with
// `<Module>_`-prefixed names — the sibling of the package-root bridge, which serves
// the cross-package form of the same convention. Type-only (erased at runtime); the
// contract shape stays single-source in the .res modules.
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
} from './Protocol.gen';
export type {
  componentKind as GraphOps_componentKind,
  edgeKind as GraphOps_edgeKind,
  graphEdge as GraphOps_graphEdge,
  graphLeaf as GraphOps_graphLeaf,
  graphNode as GraphOps_graphNode,
  leafGroups as GraphOps_leafGroups,
  readCandidate as GraphOps_readCandidate,
  subgraph as GraphOps_subgraph,
} from './GraphOps.gen';
export type {legendEntry as D2Legend_legendEntry} from './D2Legend.gen';
export type {
  gEdge as DomainGraphD2_gEdge,
  gNode as DomainGraphD2_gNode,
  subgraph as DomainGraphD2_subgraph,
} from './DomainGraphD2.gen';
