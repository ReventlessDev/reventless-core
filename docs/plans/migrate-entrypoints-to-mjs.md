# Migrate Lambda EntryPoint Files from ReScript (.res) to Plain ESM (.mjs)

**Status**: Code migration complete (commit `e43ca30a`). Pending: deploy + smoke test.

## Rationale

The 14 Lambda entry point files in `reventless-aws/src/adapter/Runtime/` were ReScript in name only — every file used `'a => 'b` signatures, `%raw` blocks, `Obj.magic` casts, and `@module external` bindings with no type safety. This caused a production bug where `Stream.runCollect` returned a Chunk (not an array), hidden by untyped bindings (`results.map is not a function`).

Migrated all files to hand-maintained `.mjs`, based on compiled `.res.mjs` output with ReScript runtime dependencies replaced by inline JS. Net reduction: ~3,280 lines.

## What Changed

- **14 `.res` files deleted**, replaced by 14 `.mjs` files (13 entry points + HandlerFactoryHelpers)
- **15 builder `.res` files updated** — re-export paths changed from `*EntryPoint.res.mjs` to `*EntryPoint.mjs`
- **Layer builder comment updated** in `DependencyBundler_PostProcess.res`
- **Chunk bug fixed** in DcbCommandTopicEntryPoint and AutomationSliceEntryPoint via `Chunk.toReadonlyArray`

## Completed Phases

- [x] **Phase 1**: HandlerFactoryHelpers + HeartbeatEntryPoint (proof of concept)
- [x] **Phase 2**: SideEffectEntryPoint, TaskBucketEntryPoint (low risk)
- [x] **Phase 3**: ReadModel, EventMapper, ExtensionPoint, PluginExtensionPoint, Counter (high complexity)
- [x] **Phase 4**: Aggregate, StateViewSlice, AutomationSlice, AdminEventCollector, DcbCommandTopic (critical)
- [x] **Phase 5**: Cleanup — verified no `.res` entry point files remain, updated layer builder comment

## Remaining

- [ ] Verify on next deploy — confirm all Lambda types run without errors in CloudWatch Logs

## Rollback

All `.res` files are preserved in git history. If a migrated `.mjs` causes issues, revert commit `e43ca30a`.
