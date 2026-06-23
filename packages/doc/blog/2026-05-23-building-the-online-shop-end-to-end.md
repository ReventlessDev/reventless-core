---
slug: online-shop-end-to-end
title: Building the online shop, end to end
authors: [reventless]
tags: [case-study, event-sourcing]
date: 2026-05-23
draft: true
---

The clearest way to understand Reventless is to follow one application all the way
through: understand the model, run it locally, deploy it to AWS, and test it
live. That's exactly what the online-shop tutorial does — and it's a real,
working package in the repo, not a sketch.

<!-- truncate -->

## One spine, four steps

The [tutorial](/tutorials/get-started) is a single guided track built on
`examples/online-shop-hybrid/`:

1. **Understand it** — the [hybrid walkthrough](/tutorials/hybrid-based) covers
   every command, event, read model, slice, and the cross-plugin extension-point
   protocol. Category and Customer are aggregates; Product/ProductDemand and
   Order/CatalogProduct are DCB slices.
2. **Run it locally** — [start the whole shop](/tutorials/run-locally) on the
   local platform with one command, served through a local GraphQL API and the
   host-shell UI.
3. **Deploy it to your AWS account** — [fork-and-deploy](/tutorials/deploy-to-aws)
   with Pulumi: point the stacks at your own org, pick your Cognito setup, and ship.
4. **Test it on AWS** — [verify](/tutorials/test-on-aws) the live stack, including
   subscriptions flowing over WebSockets.

## Why hybrid?

Real applications have both kinds of entity — independent lifecycles and
interdependent ones — so the shop uses a hybrid plugin and lets each entity pick
its model. The composition root that wires it all is **generated** from the folder
layout; you add a file, the generator wires it. See
[aggregate vs DCB](/blog/aggregate-vs-dcb) for how to make that call per entity.
