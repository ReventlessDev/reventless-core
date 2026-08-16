---
title: What is a Dynamic Consistency Boundary?
sidebar_label: What is a DCB?
---

# What is a Dynamic Consistency Boundary?

Every write-side design has to answer one question: **when a command arrives,
what does the system have to know in order to say yes?** A Dynamic Consistency
Boundary is one answer to it — and the vocabulary below is the whole idea, so it
is worth defining the words before using them.

## The problem it solves

Classic event sourcing draws the consistency boundary around an *entity*. A
product has its own event log; a decision about that product reads that log and
appends to it. Two commands for the same product are ordered against each other,
and commands for different products never interact. That is an **aggregate**, and
when entities really are independent it is the simplest thing that works.

It stops working the moment a decision needs to see *somebody else's* events.
"Reject a product whose category does not exist or has been archived" is a
decision about a product that depends on facts about a category. With one log per
entity there is no way to read both consistently: you can query the category's
current state, but between reading it and appending your event, it can be
archived.

DCB draws the boundary around the **decision** instead of around the entity. The
entities share one log, the decision reads exactly the events it needs across
whichever entities it needs them from, and the append is rejected if any of those
facts changed while it was thinking.

## The vocabulary

**Tag.** A key attached to an event that makes it findable — almost always an
entity id. `CategoryAdded` carries the tag `categoryId: "books"`. Tags are what
let many entities' events share one log and still be read apart: a query is a
filter over tags, not a scan.

**Partition.** Where an event physically lives in storage. Events sharing a
partition key are stored and ordered together. When an event carries more than
one id, one of them is marked as the partition tag — the others remain queryable
but do not decide placement.

**Decision model.** The state a slice builds to answer one command. It is
produced by reading the relevant events and folding them with `evolve`, starting
from `initialState`. It is **ephemeral**: rebuilt per command, used once by
`decide`, then discarded. Nothing persists it, and nothing else can see it.

**Fence.** The condition attached to the append. Having read events for a set of
tags, the slice appends on the condition that *no new event carrying those tags
has been recorded since it read*. If one has, the append is rejected and the
whole read-decide-append cycle retries against the newer history. This is
optimistic concurrency: no locks, no coordination, and a conflict costs a retry
rather than a wrong answer.

Put together: **read by tags → evolve into a decision model → decide → append
behind a fence on those same tags.**

## What that buys you

The boundary is *dynamic* because it is decided per command, from what the
command actually read. Two commands that touched no common tag do not conflict,
however close together they arrive. Two that did are serialised against each
other — exactly the ones that had to be.

So a slice can enforce a rule spanning several entities without the entities
being merged into one big aggregate to make it possible, and without the
usual alternative of "read it first and hope".

## What it costs

- **Events must be tagged correctly.** A missing tag means a decision reads less
  than it should, and the fence protects less than you think. Most tags are
  inferred from `*Id` field names, which is why the naming convention matters.
- **A shared log means a shared schema.** The log's event type is the union of
  every slice's events. That is derived rather than declared, so it cannot drift
  — but it does mean the slices in a plugin are coupled through the log.
- **Retries are real.** A hot tag — one entity every command touches — serialises
  everything that touches it. If a rule needs that, the retry is the cost of the
  rule; if it does not, the tag is too broad.
- **You have to think about scope.** Does this decision need one entity's history,
  or every event carrying this key across all partitions? Most of the time the
  framework infers it from how your slices reference each other; the case it
  cannot see is when a slice reads its own event type across partitions, such as
  a capacity limit.

## Choosing between this and an aggregate

Ask it per entity, not per application:

1. **Does a decision about this entity need another entity's events?** → DCB.
2. **Does another entity's decision need *this* entity's events?** → DCB, even if
   this entity looks perfectly self-contained on its own. Its events have to be
   in the shared log for the other slice to reach them.
3. **Neither?** → an aggregate. Simpler, isolated, and no shared schema.

Answering (2) with a self-contained entity is the case people get wrong. In the
worked example, `Category` is an unremarkable add/rename/archive lifecycle and
would make a fine aggregate — but `AddProduct` reads `CategoryAdded` and
`CategoryArchived` to decide, so `Category` has to be DCB.

The full version of this question, with the trade-offs written out, is the
[aggregate vs DCB decision guide](../aggregate-vs-dcb-decision-guide.md).

## Next

- [DCB slices](../dcb-slices.md) — writing one
- [DCB usage](../dcb-usage.md) — tags, partitioning, and cross-partition reads
- [How the fence is enforced](/framework/internals/dcb-consistency-checks) —
  the storage-level detail
