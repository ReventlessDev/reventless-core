---
title: Advanced Usage
date: 2021-11-22
draft: true
---

# Advanced Usage

## Extension Points
Plugins are independent of each other by default. `Extension Points` serve as a declarative way of describing possible interactions between Plugins.  

In general, an `ExtensionPoint` serves as a filter and translator of a Plugin's internal Commands / Events. This is usefull to not leak abstractions of one Plugin to another and keep the `ExtensionPoint`'s Spec stable.

- an `ExtensionPoint` maps Events of Aggregates of it's Plugin to Events of itself (`ExtensionPoint`) and publishes these Events to all related `Extension`s
- an `ExtensionPoint` receives Commands from `Extension`s and maps them to commands for Aggregates of it's Plugin

> **TODO**: add overview graphic to show relations between ExtensionPoint, Extension and Plugin components.

See detailed [explanation of Extension Points](./reventless-components/extensionpoint.md) for more information.

## Extension



See detailed [explanation of Extension](./reventless-components/extension.md) for more information.
