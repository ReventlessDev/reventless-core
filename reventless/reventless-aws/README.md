[![npm version](https://img.shields.io/npm/v/@reventlessdev/reventless-aws.svg?label=version)](https://www.npmjs.com/package/@reventlessdev/reventless-aws)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Changelog](https://img.shields.io/badge/📋-Changelog-blue)](./CHANGELOG.md)

# `reventless-aws`

Reventless suplements to run Reventless applications on Amazon AWS.
This package extends `reventless`.

## Usage

- Add `reventless-aws` to your dependencies in `package.json`.
- Add `reventless-aws` to your dependencies in `rescript.json`.
- For general information see this monorepo's [readme](../../README.md)

## Introduction

### Reventless Component

Reventless uses [Pulumi](https://www.pulumi.com/docs/intro/concepts/programming-model/#components) components to create reusable parts of software. A component bundles several (cloud) resources which act together to fulfill a specific task (e.v. `EventLog`) in our system.  
Components always consist of code run at deploytime **and** code run at runtime.

[Reventless](../reventless/README.md) implements only general cloud-provider-agnostic components. These components need to be parameterized with cloud-provider-specific *adapters*.

### Adapter

Adapter implement cloud-provider-specific functionallity. An adapter chooses the cloud-provider's resource(s) and provides specialized functions to be used for a specific component.  
E.g. adapter for the `EventLog` could choose to store it's data in a database-service or a filestorage-service and would provide functions which implement an eventlog's functionality (`replay` & `append`).


## Example

```
// TODO: DEMONSTRATE API
```

## Contribution

### Changelog

Please remember to update the changelog for any modifications accordingly!


### Folder Structure

```sh
reventless-aws
├── src
│   ├── adapter                 [adapter per Reventless Component]
│   │   ├── AtomicCounter
│   │   ├── CommandGenerator
│   │   ├── CommandTopic
│   │   ├── DataCleaner
│   │   ├── EventCollector
│   │   ├── EventLog
│   │   ├── EventTopic
│   │   ├── QueryDb
│   │   └── ScheduledPublisher
│   ├── components              [components preconfigured with aws adapter]
│   └── util                    [util functions by aws-resource, used by several adapters]
└── __tests__                   [tests for adapters & utils]
```