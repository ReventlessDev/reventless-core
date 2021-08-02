---
title: Get Started
date: 2021-11-22
draft: true
---

# Get Started

## Basics

When implementing a system based on Reventless you should only think about `commands` and `events`. These provide easy to understand reasoning for anything happening.  
Great care should go into naming these according to the [ubiquitous language](https://www.martinfowler.com/bliki/UbiquitousLanguage.html) of the project / context.  
`Command`s are usually named in imperative, while `event`s are usually named in past tense. (e.g: doSomething vs somethingDone).

Since `command`s are only a formulated desire for change, they can potentially be rejected with an `error`. `Event`s are absolute facts and the result of `command`s, which will never change once issued.

## Reventless Components

### Aggregate

[`Aggregate`s](https://www.martinfowler.com/bliki/DDD_Aggregate.html) are the entities in your system.  
An `Aggregate` receives `command`s and outputs `event`s (or `error`s) based on the current state. (`(command + current state) => (new event or error)`). A single `command` can result in *any number* of `event`s.  
The current `state` will never be persisted to storage. Only the Aggregate's events will be stored. If a new `command` gets handled the actual `state` will be calculated based on the previous `event`s. ([Event-Sourcing](https://martinfowler.com/eaaDev/EventSourcing.html)) Because the `state` won't be persisted, you should only put data there, you *really* need for validating incoming `command`s.

```mermaid
graph LR
    command((command)):::command -->|1| Aggregate:::aggregate -->|*| events((events)):::event

    classDef command stroke:#66f,color:#66f,fill:none;
    classDef event stroke:#fa0,color:#fa0,fill:none;
    classDef aggregate fill:#ff6,stroke:#333,color:#333;
```

- **responsibility**: ensure only valid commands create events having the necessary information attached
- **in**: `command`
- **out**: `event`s

### ReadModel

> TODO: add description

```mermaid
graph LR
    event((event)):::event -->|*| ReadModel:::readmodel

    classDef command stroke:#66f,color:#66f,fill:none;
    classDef event stroke:#fa0,color:#fa0,fill:none;
    classDef aggregate fill:#ff6,stroke:#333,color:#333;
    classDef readmodel fill:#9c5,stroke:#333,color:#333;
```

- **responsibility**: create and persist state to be queried
- **in**: `event`s
- **out**: -

### EventMapper

> TODO: add description

```mermaid
graph LR
    events((events)):::event -->|*| EventMapper{EventMapper}:::eventmapper -->|*| commands((commands)):::command

    classDef command stroke:#66f,color:#66f,fill:none;
    classDef event stroke:#fa0,color:#fa0,fill:none;
    classDef aggregate fill:#ff6,stroke:#333,color:#333;
    classDef readmodel fill:#9c5,stroke:#333,color:#333;
    classDef eventmapper fill:#66f,color:#fa0,stroke:#fa0;
```

- **responsibility**: generate `commands` for a given `aggregate` based on (multiple) other `aggregate`s' `events`
- **in**: `event`s
- **out**: `command`s

### Task

> TODO: add description

#### SideEffect

> TODO: add description

```mermaid
graph LR
    events((events)):::event -->|*| SideEffect{SideEffect}:::sideeffect -->|calls| Task>Task]:::task

    classDef command stroke:#66f,color:#66f,fill:none;
    classDef event stroke:#fa0,color:#fa0,fill:none;
    classDef aggregate fill:#ff6,stroke:#333,color:#333;
    classDef readmodel fill:#9c5,stroke:#333,color:#333;
    classDef eventmapper fill:#66f,color:#fa0,stroke:#fa0;
    classDef sideeffect fill:#f4f,color:#fa0,stroke:#fa0;
    classDef task fill:#f4f,color:#333,stroke:#333;
```

- **responsibility**: execute `functions` of a given `task` based on (multiple) `aggregate`s' `events`
- **in**: `event`s
- **out**: -

### Service

> TODO: add content

### Plugin

> TODO: add content

## Development Setup

### Install VS Code

- install [Visual Studio Code](https://code.visualstudio.com)
- install [reason-vscode](https://marketplace.visualstudio.com/items?itemName=jaredly.reason-vscode) (extension id: `jaredly.reason-vscode`)

### Install Node

- install [Node 12.x](https://nodejs.org/download/release/latest-v12.x/) (as of this writing, this version is the current LTS version in maintainance untill 30.04.2022)

### Initialize a new Project

Run `npm init` in the directory you want to create the new project and answer all questions.

### Install Dependencies

Run `npm i @bs-platform@5.2.1 @pulumi/pulumi @pulumi/aws @reventless/reventless-spec` inside your project directory.

### Choose a Cloud Provider

The Reventless-Framework is cloud-provider agnostic. Therefore there is a different package per provider, which contains pre-configured default components and the necessary adapters to configure the components yourself when needed.  
The packages are called `@reventless/reventless-<providerName>` (e.g. `@reventless/reventless-aws`)

> Currently we support only AWS out of the box, but plan to increase the supported provider in the future.

Choose the according package and install it by running e.g. `npm i @reventless/reventless-aws` inside your project directory.

### Core- & API-Stack

A [`Stack`](https://www.pulumi.com/docs/intro/concepts/stack/) is the actual deployment unit used by our infrastructure as code tool of choice [Pulumi](https://www.pulumi.com).  
The foundation of any platform built using Reventless is a Core-Stack. This is the central piece providing the necessary functionalities for `Plugins` to interact with each other.

> **TODO**: complete this area and below!

## Create a new Plugin

### `Plugin`

Deployment-unit

### `Aggregate`

### `ReadModel`

#### Update API Schema

### `Aggregate` #2

### `EventMapper`

Aggregate1.event >> EventMapper >> Aggregate2.command

### `Task`
