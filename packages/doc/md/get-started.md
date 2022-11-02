---
title: Get Started
date: 2021-11-22
draft: true
---

## Basics

When implementing a system based on Reventless you should only think about `commands` and `events`. These provide easy to understand reasoning for anything happening.  
Great care should go into naming these according to the [ubiquitous language](https://www.martinfowler.com/bliki/UbiquitousLanguage.html) of the project / context.  
`Command`s are usually named in imperative, while `event`s are usually named in past tense. (e.g: doSomething vs somethingDone).

Since `command`s are only a formulated desire for change, they can potentially be rejected with an `error`. `Event`s are absolute facts and the result of `command`s, which will never change once issued.

## Reventless Components

Find an overview of the most important Reventless Components in [reventless-components-overview.md](./reventless-components-overview.md).

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
