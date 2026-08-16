---
title: How it compares
sidebar_label: How it compares
sidebar_position: 5
---

# How it compares

Reventless is not the only reasonable way to build the applications it targets.
This page sets out what it does differently from the two most common
alternatives, and — as honestly as we can put it — what you give up by choosing
it.

## Compared with assembling serverless plumbing yourself

The alternative here is a conventional cloud project: functions, queues, tables,
API definitions, permissions, and deployment code, all written and wired by hand.

| | Hand-assembled | Reventless |
|---|---|---|
| **Infrastructure** | You choose, write, and maintain the definitions for every resource, plus the permissions between them. | Derived from the domain description and provisioned in your account. |
| **Wiring** | Each new event needs its producer, its transport, its consumers, and its permissions connected by hand. | Connecting a new event to a view or another part of the system is a declaration. |
| **Consistency of the whole** | Nothing checks that the storage layout, the API, the handler, and the UI agree. Drift is found in production. | One description; the compiler rejects a mismatch before deployment. |
| **Time to first working system** | Weeks of scaffolding before the first business rule runs. | The scaffolding is not yours to write. |
| **Control over details** | Total. | High but bounded: you configure the derived resources, you do not hand-author each one. |

The trade is explicit: you give up bespoke control of every resource in exchange
for never maintaining the wiring between them. If your application's value is in
an unusual infrastructure topology, that is a bad trade. If it is in the domain
rules, it is a good one.

## Compared with a CRUD framework

The alternative here is a mature, conventional stack — an ORM over a relational
database, request handlers, a REST or GraphQL layer, and an admin UI.

| | CRUD stack | Reventless |
|---|---|---|
| **What is stored** | Current state; updates overwrite. | Every change, in order, as an immutable fact. Current state is derived. |
| **Audit trail** | A separate concern: a log table, triggers, or an audit library — written by hand and easy to bypass. | Inherent: the history *is* the store. |
| **New questions about old data** | Answerable only if you happened to record the right columns. | Answerable by projecting existing history into a new view. |
| **Reads and writes** | Usually the same model, so read load and write rules pull against each other. | Separate by construction; views are shaped for the screens that use them. |
| **Layer drift** | Schema, model, API type, and UI form are all maintained by hand and drift apart. | One description; the rest is derived. |
| **Ecosystem** | Vast — decades of libraries, tooling, and hiring pool. | Young and small. |
| **Familiarity** | Most developers already know it. | Event sourcing has to be learned. |

## What you give up

We would rather you know these before you start than discover them in month
three.

- **Event-sourced thinking is a genuine shift.** Modelling in facts rather than
  rows takes practice, and the first design is usually not the best one.
  Deciding where consistency boundaries belong is real domain work that no
  framework does for you.
- **History is permanent, which cuts both ways.** Correcting the past means
  recording a compensating fact, not editing a row. That is the right behaviour
  for auditable systems and a nuisance for casual data cleanup.
- **Evolving events needs care.** Once a fact is recorded, code that reads it has
  to keep being able to read it. Adding a field is easy; changing the meaning of
  one is a migration you must think about.
- **The ecosystem is young.** Fewer libraries, fewer worked examples, fewer
  people who have already solved your exact problem. AI assistance closes some of
  that gap, and the documentation you are reading is part of the same effort, but
  it is not the same as a twenty-year-old ecosystem.
- **The description vocabulary is new to most teams.** It is small and mostly
  written with AI assistance, but it is not a language your next hire already
  knows.
- **Production deployment means AWS today.** The provider seam and the relational
  storage engine exist, but a sovereign or on-premise production target does not
  ship yet — see [Deployment](./deployment.md).

## When to choose it

Reventless is a good fit when several of these hold: what happened matters as
much as what is currently true; the domain has real rules rather than forms over
tables; you need an audit trail you can defend; you expect to serve new views of
existing data over time; and you would rather spend your effort on domain rules
than on infrastructure wiring.

It is a poor fit when the domain is thin, the data has no meaningful history, the
team must ship on a stack it already knows this quarter, or the value of the
system lies in a bespoke infrastructure design.

## Next

- [See it run](/tutorials/get-started) — the worked example, locally and on AWS
- [Build your own](/app/get-started) — start an application from your own domain
