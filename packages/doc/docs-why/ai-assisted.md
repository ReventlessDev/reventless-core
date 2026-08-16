---
title: How AI helps you build
sidebar_label: How AI helps you build
sidebar_position: 3
---

# How AI helps you build

Reventless was designed for a workflow in which an AI assistant writes most of
the description and a compiler plus your own scenarios decide whether it is
right. That combination is what makes generated code trustworthy here rather
than merely fast.

## Describe the domain in your own words

You start from a description a domain expert would recognise:

> *"A catalog of products. Products can be added, renamed, and repriced.
> Categories can be created and archived. Other parts of the system need to know
> when a product becomes available or changes price."*

From that, an assistant produces the specs — the commands, the events, the
decision rules, the views, and the connections between the parts — as a
complete, compiling application. The [Getting started with AI-assisted
development](/app/ai-assisted/getting-started) page shows the hands-on version,
including the commands that scaffold a new application or add a part to an
existing one.

## Three things keep the result honest

**The vocabulary is small and closed.** There is one way to express a command, an
event, a decision, and a view. An assistant is not choosing between frameworks,
folder layouts, or persistence strategies — the shape of the answer is fixed, so
there is far less room to invent something plausible but wrong.

**The compiler checks the result immediately.** A decision that forgets a case, a
view that reads a field no event carries, a command whose payload does not match
its handler — none of these compile. Errors surface at generation time, in the
assistant's own loop, not in production.

**Your scenarios are the acceptance test.** Given/When/Then examples are written
in the same domain vocabulary as the specs, so you can read and correct them
without reading the implementation. They run as automated tests, which means
generated logic is *verified against rules you agreed to*, not trusted because it
looks reasonable. When you change your mind about a rule, you change the
scenario, and the failing test tells you exactly what else must move.

## Assistants can also operate the running application

Every Reventless application exposes its commands and views over
[MCP](https://modelcontextprotocol.io/) alongside the GraphQL API. An assistant
connected to a running application can look at real data and issue real
commands — through the same authorization rules that apply to a human user.

That is useful well beyond development: exploring what the system currently
believes, reproducing a support issue against real history, or driving a routine
operational task by description rather than by clicking through screens.

## What stays yours

The domain is yours to decide. Which facts matter, what the rules are, which
consistency boundaries the business actually requires — an assistant proposes,
but these are business decisions, and the scenarios are where you record them.
The generated application is ordinary source code in your repository, with no
runtime dependency on any AI service.

## Next

- [Deployment: fast now, sovereign later](./deployment.md)
- [AI-assisted development, hands-on](/app/ai-assisted/) — the practical guide
