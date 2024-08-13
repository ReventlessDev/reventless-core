---
title: Introduction to Reventless
date: 2021-11-22
draft: true
sidebar_position: 1
---

**Reventless** is a modern holistic approach for the development of event-based business applications, consisting of

- a *Methodology* which covers the full delivery cycle
- a *Programming Model* which focuses on business value
- a *Domain Independent* reusable *Framework* to optimize operational costs.

It is used in production for a customer in the financial industry since 2019.

## The Reventless Mindset

> Focus on business value and ship fast.

other Suggestions:

- > Create value fast and iterate to improve.
- > Create value fast and ship with confidence.

## The Reventless Methodology

- gather requirements in an efficient and customer centric manner
  - Event Storming workshop (online or on site) with all relevant stakeholders, especially domain experts
  - low effort requirement specification
  - zero waste: requirements are easily translated to formalized specifications that are directly run by the framework
- use of a common (ubiquitous) language / vocabulary across all stakeholders to foster better communication and understanding
  - improved communication efficiency
- focus on business centric tests
  - high quality through behaviour driven test
  - very readable tests in common language to discuss with customers and users

## The Reventless Programming Model

- everything evolves around commands & events (which are part of the ubiquitous language)
  - improved communication efficiency
  - reduced complexity (in high level view(s))
  - better tracability of actions & triggers in the system
- enable developers to focus on the value generating business logic and reduce repetitive coding tasks
  - reduce mental overhead
- hirarchical component model guides towards best-practice architectural patterns
  - helps to utilize best-practice architectural patterns
  - allows teams to develop and deploy services independently
- declarative definition of interaction between different parts of the system
  - improve communication between developers / teams
  - enable to introduce changes, while keeping other partes of the system stable

## The Reventless Framework

- serverless
  - "pay as you go", very low operational costs
  - automatically scaling up & down
- cloud provider agnostic
  - no vendor lock-in
- highly adaptable through effortless configuration
  - easily adapt the infrastructure to your requirements
- focus on business logic
  - improved time to market
  - no cloud experts needed for application development
  - benefit from future framework improvements and optimizations
- type driven
  - whole system: backend, API, frontend
  - great refactoring support, avoid most errors when evolving applications
- full stack approach
  - same programming language for whole system
  - easy for developers to switch between frontend & backend
  - reuse backend business functionality for frontend
- behaviour driven test support
  - test framework makes it easy to achieve high quality applications

## Reventless stands on the shoulders of giants

### Reventless is based on the following Concepts

- [Domain-Driven-Design](https://en.wikipedia.org/wiki/Domain-driven_design)
- [Event-Storming](https://en.wikipedia.org/wiki/Event_storming)
- [Microservices with Event-Based communication](https://en.wikipedia.org/wiki/Microservices)
  - [Event-Sourcing](https://en.wikipedia.org/wiki/Domain-driven_design#Event_sourcing)
  - [CQRS (Command Query Responsibility Segregation)](https://en.wikipedia.org/wiki/Domain-driven_design#Command_Query_Responsibility_Segregation)
- [Serverless Computing](https://aws.amazon.com/serverless/)

### Reventless Framework is based on the following tech-stack

- [Rescript](https://rescript-lang.org/): functional Programming Language, compiling to JavaScript
- [Pulumi](https://www.pulumi.com/): Infrastructure as Code
- [Node.js](https://nodejs.org): Compile target & runtime environment

## Get Productive

1. [Get started](./get-started.md) by reading [this guide](./get-started.md).
2. Learn about [avanced usage](./advanced.md) scenarios by reading [this](./advanced.md).
3. Get your hands dirty by reading an in-depth description about the [inner workings of the Reventless framework](./framework-inner-workings.md).

## Roadmap

### Important Next Steps

- Documentation ([#13](https://gitlab.com/reventless/reventless-universe/-/issues/13))
- compiler update ([#1](https://gitlab.com/reventless/reventless-universe/-/issues/1))
- API Schema generation ([#68](https://gitlab.com/reventless/reventless-universe/-/issues/68))
- Command- & Event- Versioning ([#49](https://gitlab.com/reventless/reventless-universe/-/issues/49), [#63](https://gitlab.com/reventless/reventless-universe/-/issues/63))
- multiple ReadModels ([#87](https://gitlab.com/reventless/reventless-universe/-/issues/87))
