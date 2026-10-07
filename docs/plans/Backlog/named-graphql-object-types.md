# Plan: a record schema can carry its own GraphQL type name

**Date:** 2026-10-07<br/>
**Status:** Backlog — extracted from [../done/derive-admin-api-sdl-from-schemas.md](../done/derive-admin-api-sdl-from-schemas.md) when it closed (its step 1). Waits for a consumer: a domain read model that uses one nested record in two fields, or a decision to resume that plan's steps 2–5.<br/>
**Relates to:** [typed-graphql-sdl-from-sury.md](typed-graphql-sdl-from-sury.md)

---

## In plain words

The GraphQL schema generator names a nested object type after the path that
reached it: parent type name plus the capitalised field name
(`SchemaType.shapeOf`, `Object` branch, in
`reventless/core/src/components/Api/SchemaType.res`). So one record used by two
fields is emitted as **two identical types under two names**, and a shared
record has no way to say what it is called.

Two special cases already work around this:

- `SchemaType.semanticCompositeNames` / `canonicalName` give `Money`,
  `DateRange`, `GeoPoint` and `CaptionedImage` a fixed name wherever they appear.
- `Reventless.TaggedUnion.named` puts a union's name on its schema, so the SDL
  emitter and the write-time `__typename` stamp agree.

## What is left

Generalise the two: a marker that puts a GraphQL type name on **any** record
schema, read in `shapeOf`'s `Object` branch ahead of the path-derived name, with
the path name as the fallback. Follow the union precedent — the name lives on the
schema, not in a generator table, so every walker that reaches the field gets the
same answer.

Why it matters on its own terms: merged-API composition unions types only when
they are identically named, and today any read model with two fields of the same
nested record ships two definitions of it. The semantic composites could then
move onto the generic marker and `semanticCompositeNames` becomes their
registration rather than a special case.

## The admin API steps that depend on it

The parent plan's steps 2–5 (derive the three admin API SDL strings from new
`@schema` wire records, then encoders from sury, then drop the strings) need this
first: without it the component-level types shared between
`Platform_ComponentDefinitions` and `Platform_PluginStructures` would be emitted
under two names. Its "When to stop" still holds: do not start steps 2–5 while
its delta table of breaking wire changes is still growing. (One entry may have
moved since: `shapeOf` now maps `Int32` numbers to `Int`, so check whether the
`sortOrder` row still applies.) The drift guard
`reventless/core/tests/admin/AdminApiSchemaDriftTest.res` covers the
silent-omission risk in the meantime.

## Done looks like

- A record schema marked with a name emits one type under that name, from any
  number of fields, in the domain SDL and the admin SDL alike.
- An unmarked record keeps its path-derived name (no golden moves).
- `pnpm run check:graphql` goldens refreshed in the same commit if an adopter
  moves them.
