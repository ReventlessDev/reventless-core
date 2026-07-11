// Hand-written IN-PACKAGE genType type bridge (NOT generated — un-ignored in
// .gitignore). When one module of this namespaced package references another's
// genType types, genType emits an import of './ReventlessVscodeProtocol.gen' RELATIVE
// TO src/ with `<Module>_`-prefixed names — the sibling of the package-root bridge,
// which serves the cross-package form of the same convention. Type-only (erased at
// runtime); the contract shape stays single-source in `Protocol.res`.
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
