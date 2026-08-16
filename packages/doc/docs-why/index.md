---
title: What is Reventless?
sidebar_label: What is Reventless?
sidebar_position: 1
slug: /
---

# What is Reventless?

Reventless is a platform for building business applications from a **description
of your domain** instead of from hand-written layers of plumbing.

You describe two things:

- **Specs** — what the application is made of: the commands people can issue
  (*place an order*), the events those commands produce (*order placed*), and the
  views people read (*my orders*, *products in stock*).
- **Scenarios** — worked examples in Given/When/Then form: *given* these past
  events, *when* this command arrives, *then* these events follow — or this
  rejection. Scenarios are written in the same vocabulary as the specs and run as
  automated tests.

From those, the platform derives the rest: the storage that records what
happened, the APIs your clients and AI assistants call, a working user interface,
and the cloud infrastructure it all runs on.

## Everything that happens is recorded as a fact

A Reventless application does not store the *current* state of your business and
overwrite it as things change. It stores the **sequence of events** that got you
there — *order placed*, *payment received*, *item shipped* — and derives current
state from that sequence.

This is called *event sourcing*, and it changes what your system can tell you:

- **A complete audit trail comes for free.** Every change has a cause, an actor,
  and a timestamp, because the change *is* the record — not a log written
  alongside it that can drift or be skipped.
- **You can ask questions you did not plan for.** New views are built by
  replaying history, so a report nobody asked for last year can still be
  answered from data you already have.
- **Reads never block writes.** Views are maintained separately from the decision
  logic that accepts commands, so heavy queries and busy write paths do not
  contend for the same resources.

## Decisions and views are separate concerns

Accepting a command is a decision: *may this happen, given what has happened so
far?* Showing a list of orders is a projection: *given everything that happened,
what should this screen say?*

Reventless keeps these apart by construction. You write the decision rules once,
in domain terms, and you write each view as a projection over events. The
platform maintains the views, keeps them current as new events arrive, and pushes
updates to connected clients live.

## One source of truth, no glue code

In a conventional stack, the same concept is spelled out several times: a
database schema, an API type, a validation rule, a UI form, an integration test
fixture. Each is written by hand and each can drift from the others.

In Reventless there is one description. The storage layout, the GraphQL API, the
MCP interface for AI assistants, the generated user interface, and the deployed
infrastructure are all derived from it. Change the description, and the derived
system changes with it — there is no second place to update and nothing to keep
in sync.

## What this is good for — and what it is not

Reventless suits applications where **what happened matters as much as what is
true now**: order management, inventory, bookings, claims, approvals, ledgers,
anything auditable or regulated.

It is a poor fit for applications with no meaningful domain events — a static
content site, a pure data-transformation pipeline, or a thin CRUD admin over
somebody else's database.

## Next

- [What you provide, what you get](./what-you-provide.md) — the contract, concretely
- [How AI helps you build](./ai-assisted.md) — describing a domain in your own words
- [Deployment: fast now, sovereign later](./deployment.md) — where your application runs
- [How it compares](./how-it-compares.md) — honest trade-offs against the alternatives
