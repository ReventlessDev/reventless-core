---
title: Get Started
---

# Get started building an app

There are two ways to start a Reventless application. Most people should use the
first.

## Option 1 — Describe your domain (recommended)

Reventless applications are generated well by AI assistants, because the
vocabulary is small and closed and the compiler checks the result immediately.
The practical path is: describe what your domain does, review what comes back,
and correct it through scenarios.

In an assistant that has this project's skills available (Claude Code, Cursor,
Copilot, or Codex), run:

```
/reventless-new online-shop
```

and describe your domain in your own words:

> "A catalog of products. Products can be added, renamed, and repriced.
> Categories can be created and archived. Other parts of the system need to know
> when a product becomes available or changes price."

The assistant proposes an architecture, asks you to confirm it, generates the
whole project — specs, decisions, views, cross-plugin connections, tests, and
configuration — and builds it to confirm it compiles cleanly.

See [AI-assisted development](./ai-assisted/getting-started.md) for the full
workflow, including `/reventless-add` for growing an existing project and
`/reventless-validate` for checking one.

**You still make the domain decisions.** Which facts matter, what the rules are,
and where consistency boundaries belong are business questions — the assistant
proposes, and your [scenarios](./given-when-then.md) are where you record the
answer.

## Option 2 — Scaffold it yourself

If you would rather assemble the project by hand, or you are adding Reventless to
an existing repository:

**Prerequisites.** [Node.js 22.17.1](https://nodejs.org/) (see `.node-version`)
and pnpm 10 via Corepack (`corepack enable && corepack prepare pnpm@10 --activate`).
For editing, [VS Code](https://code.visualstudio.com) with the
[ReScript extension](https://marketplace.visualstudio.com/items?itemName=rescript-ide.rescript-vscode).

**Create the project and add the packages.** They are published under the
`@reventlessdev` scope on the GitHub Package Registry:

```bash
pnpm init
pnpm add @reventlessdev/reventless-spec @reventlessdev/reventless-infra sury
pnpm add -D @reventlessdev/reventless-ppx @reventlessdev/reventless-gwt rescript sury-ppx
pnpm add @reventlessdev/reventless-local     # or -aws, see "Choosing a platform"
```

**Add the build scripts** to `package.json`:

```json
{
  "scripts": {
    "generate": "generate-plugin src/",
    "prebuild": "pnpm run generate",
    "build": "rescript build",
    "clean": "rescript clean",
    "start": "rescript watch"
  }
}
```

`generate-plugin` scans `src/` and writes the composition root `src/Plugin.res`
before each build, wiring together everything it finds. See
[Connect plugins](./plugin-system.md) for what it wires.

**Configure the compiler** with a `rescript.json` in the project root. The
`reventless-ppx` entry **must** come before `sury-ppx`, and the output suffix is
`.res.mjs`:

```json
{
  "name": "my-plugin",
  "namespace": "MyPlugin",
  "ppx-flags": ["@reventlessdev/reventless-ppx/bin", "sury-ppx/bin"],
  "sources": [{ "dir": "src", "subdirs": true }],
  "dependencies": [
    "sury",
    "@reventlessdev/reventless-spec",
    "@reventlessdev/reventless-infra",
    "@reventlessdev/reventless-local"
  ],
  "suffix": ".res.mjs"
}
```

## What a spec actually looks like

Specs are written in a small declarative vocabulary: a command with its fields,
the events it can produce, the errors it can return, and a decision that maps one
to the other. Here is a complete one — a category being created:

```rescript
@@reventless.spec

@schema
type command =
  | AddCategory({categoryId: string, name: string})

@schema
type error = CategoryAlreadyExists

@schema
type event =
  | CategoryAdded({categoryId: string, name: string})
```

and the decision that goes with it:

```rescript
@@reventless.behavior

type state = {exists: bool}
let initialState = {exists: false}

let evolve = (_state, event) =>
  switch event {
  | CategoryAdded => {exists: true}
  }

let decide = (state, command) =>
  switch command {
  | AddCategory({categoryId, name}) =>
    state.exists
      ? Error(CategoryAlreadyExists)
      : Ok([CategoryAdded({categoryId, name})])
  }
```

That is the shape of nearly everything you will write: a list of cases, and a
function that pattern-matches over them. It is
[ReScript](https://rescript-lang.org), and the compiler is doing real work here —
forget a case in `decide` or `evolve` and it will not build. You do not need to
learn the language up front; the [syntax reference](./rescript-syntax.md) is
there for when a construct is unfamiliar, and the
[PPX annotations](./reventless-ppx.md) page explains the `@` markers that inject
the repetitive parts.

Commands are named in the imperative (`AddCategory`), events in the past tense
(`CategoryAdded`), both in the
[ubiquitous language](https://www.martinfowler.com/bliki/UbiquitousLanguage.html)
of your domain. A command is a request that may be refused; an event is a fact
that never changes once written.

## Choosing a platform

Reventless is provider-agnostic, and a **platform** package supplies the
components and adapters for one target:

- `@reventlessdev/reventless-local` — a single process, in-memory or SQLite, for
  development and tests
- `@reventlessdev/reventless-aws` — AWS (DynamoDB, Lambda, SQS, SNS, S3)

Each plugin is a functor over the platform, so the same application code runs
against either. Start local; the platform is a deployment choice, not an
architectural one.

## Next

Follow the spine from here:

1. [Model your domain](./aggregate-vs-dcb-decision-guide.md) — what your entities
   are and where consistency boundaries belong
2. [Write specs](./aggregates.md) — commands, events, decisions
3. [Write scenarios](./given-when-then.md) — Given/When/Then, as your test suite
4. [Views and UI](./components/readmodel.md) — what users read
5. [Connect plugins](./plugin-system.md) — extension points between bounded contexts
6. [Run and deploy](./local-development.md) — locally, then to the cloud
