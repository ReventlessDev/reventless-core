// Hand-written cross-package genType type bridge (NOT generated). When another
// package references this namespaced package's genType types, genType emits an import
// of `@reventlessdev/reventless-vscode-protocol/ReventlessVscodeProtocol.gen` with
// `Protocol_`-prefixed names. genType emits the per-module `src/Protocol.gen.ts` with
// bare names, so this root file bridges the two — re-exporting under the expected
// names. Type-only (erased at runtime); the contract shape stays single-source in
// `src/Protocol.res`.
export type {
  componentMeta as Protocol_componentMeta,
  componentRef as Protocol_componentRef,
  deadCodeFinding as Protocol_deadCodeFinding,
  failMessage as Protocol_failMessage,
  graphEdge as Protocol_graphEdge,
  graphNode as Protocol_graphNode,
  packageInfo as Protocol_packageInfo,
  streamEvent as Protocol_streamEvent,
  vsRange as Protocol_vsRange,
} from './src/Protocol.gen';
