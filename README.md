# Reventless Core

**Reventless** is a modern holistic approach for the development of event-based business applications, consisting of:

- A *Methodology* which covers the full delivery cycle
- A *Programming Model* which focuses on business value
- A *Domain Independent* reusable *Framework* to optimize operational costs

It enables developers to focus on business value and ship fast by providing a hierarchical component model that guides towards best-practice architectural patterns, with everything evolving around commands & events that are part of a ubiquitous language shared across all stakeholders.

## Core Technologies & Patterns

Reventless leverages modern architectural patterns and technologies:

- **Domain-Driven Design (DDD)** - Aligns software design with business domains and ubiquitous language
- **Event-Driven Architecture** - Asynchronous message-based communication between components
- **Event Sourcing** - Stores application state as a sequence of events (source of truth)
- **CQRS** - Separates read and write operations for optimized performance and scalability
- **ReScript** - Type-safe functional programming language compiling to JavaScript, see [here](https://rescript-lang.org)
- **AWS Serverless** - Cloud-native deployment using Lambda, DynamoDB, SQS, SNS, and more
- **Infrastructure as Code (IaC)** - Automated infrastructure provisioning and management using [Pulumi](https://pulumi.com)
- **Hierarchical Component Model** - Modular, reusable architectural components with built-in infrastructure definitions (via Pulumi)

## 📦 Packages

This monorepo contains the following packages (located in `./packages/*`):

### Framework Core

- [reventless-spec](packages/reventless-spec/README.md) - Type specifications and interfaces
- [reventless](packages/reventless/README.md) - Core framework (provider-agnostic)
- [reventless-aws](packages/reventless-aws/README.md) - AWS-specific implementations (DynamoDB, Lambda, SQS, SNS, S3 adapters)

### ReScript Bindings - AWS
- [rescript-aws-sdk](packages/rescript-aws-sdk/README.md) - Bindings for AWS SDK v3
- [rescript-pulumi-aws](packages/rescript-pulumi-aws/README.md) - Bindings for `@pulumi/aws`
- [rescript-pulumi-pulumi](packages/rescript-pulumi-pulumi/README.md) - Bindings for `@pulumi/pulumi`

### ReScript Bindings - Utilities
- [rescript-uuid](packages/rescript-uuid/README.md) - Bindings for `uuid`
- [rescript-fast-csv](packages/rescript-fast-csv/README.md) - Bindings for `fast-csv`
- [rescript-hash-obj](packages/rescript-hash-obj/README.md) - Bindings for `hash-obj`
- [rescript-moment](packages/rescript-moment/README.md) - Bindings for `moment` (shared with UI repo)

### ReScript Bindings - Node.js
- [rescript-node-streams](packages/rescript-node-streams/README.md) - Bindings for Node.js streams
- [rescript-node-zlib](packages/rescript-node-zlib/README.md) - Bindings for Node.js zlib
- [rescript-ssh2](packages/rescript-ssh2/README.md) - Bindings for `ssh2`

### Build & Tools
- [aws-lambda-layer](packages/aws-lambda-layer/README.md) - Lambda layer builder
- [doc](packages/doc/README.md) - Documentation site (Docusaurus)

### Outdated Packages

The following packages are outdated (located in `./packages_to_migrate/*`) and need to be updated:

- [rescript-k6](packages_to_migrate/rescript-k6/README.md) - ReScript bindings for k6 load testing tool
- [rescript-react-test-renderer](packages_to_migrate/rescript-react-test-renderer/README.md) - ReScript bindings for react-test-renderer
- [reventless-ci](packages_to_migrate/reventless-ci/README.md) - CI tooling for Reventless projects
- [reventless-ui](packages_to_migrate/reventless-ui/README.md) - React component library for Reventless applications
- [routes](packages_to_migrate/routes/README.md) - Typed routing with bi-directional usage

---

## 🚀 Getting Started

### Prerequisites

- **Node.js**: v22.17.1 (specified in [`.node-version`](.node-version))
- **ReScript**: 12.1.0
- **Lerna**: 9.0.3
- **Git**: For version control

### Quick Setup

```bash
# Install dependencies
npm install

# Build all packages
npm run build

# Run tests
npm run test
```

For detailed setup instructions, development workflow, and contributing guidelines, see [CONTRIBUTING.md](CONTRIBUTING.md).

## 📚 Documentation

Full documentation is available in the `packages/doc/` directory. To run the documentation site locally:

```bash
cd packages/doc
npm install
npm start
```

See [CLAUDE.md](CLAUDE.md) for detailed build commands and architecture overview.

## 🔗 Related Repositories

- **[reventless-ui](https://github.com/ReventlessDev/reventless-ui)** - React components and UI library for Reventless applications
  - Uses `rescript-moment` from this repo via file reference
  - ReScript 11.1.4 for UI compatibility

## 🏗️ Architecture

Reventless is an event-sourced CQRS framework designed for serverless infrastructure, written in ReScript.

### Package Hierarchy

```
reventless-spec (foundation)
  ↓
reventless (core framework + all bindings)
  ↓
reventless-aws (AWS adapters)
```

### Key Components

- **Aggregate** - Event-sourced aggregate root with CommandTopic, EventLog, CommandGenerator
- **ReadModel** - Query-side projection consuming events via EventCollector
- **Plugin** - Deployable unit containing aggregates, read models, extension points
- **Core** - Application core orchestrating all components

### Adapter Pattern

The framework separates deploy-time (Pulumi infrastructure) from runtime (Lambda handlers):
- `src/adapter/` - Deploy-time adapter interfaces
- `src/adapter/Runtime/` - Runtime builders (Single, PerAggregate, Micro)

AWS adapters implement:
- EventLog storage → DynamoDB
- CommandTopic/EventTopic channels → SQS (FIFO), SNS
- QueryDb → DynamoDB
- Task buckets → S3

## 📄 License

MIT

## Contributing

We welcome contributions! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for detailed guidelines on:

- Setting up your development environment
- Making changes and submitting pull requests
- Commit message conventions (Conventional Commits)
- Package management with Lerna
- Publishing packages to GitHub Registry

For release process documentation, see [RELEASE.md](RELEASE.md).

