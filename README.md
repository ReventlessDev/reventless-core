# Reventless

**Reventless** is a modern holistic approach for the development of event-based business applications, consisting of:

- A *Methodology* which covers the full delivery cycle
- A *Programming Model* which focuses on business value
- A *Domain Independent* reusable *Framework* to optimize operational costs

It enables developers to focus on business value and ship fast by providing a hierarchical component model that guides towards best-practice architectural patterns, with everything evolving around commands & events that are part of a ubiquitous language shared across all stakeholders.

This is a mono-repo containing all necessary packages for the Reventless framework.

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


## Contributing

We welcome contributions! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for detailed guidelines on:

- Setting up your development environment
- Making changes and submitting pull requests
- Commit message conventions (Conventional Commits)
- Package management with Lerna
- Publishing packages to GitHub Registry

For release process documentation, see [RELEASE.md](RELEASE.md).

## Packages

For individual Readmes per package see inside the packages directory `./packages/*`:

### ReScript Bindings

- [rescript-aws-sdk](packages/rescript-aws-sdk/README.md): ReScript bindings for `aws-sdk`
- [rescript-fast-csv](packages/rescript-fast-csv/README.md): ReScript bindings for `fast-csv`
- [rescript-hash-obj](packages/rescript-hash-obj/README.md): ReScript bindings for `hash-obj`
- [rescript-node-streams](packages/rescript-node-streams/README.md): ReScript bindings for streams in `node`
- [rescript-pulumi-aws](packages/rescript-pulumi-aws/README.md): ReScript bindings for `@pulumi/pulumi-aws`
- [rescript-pulumi-pulumi](packages/rescript-pulumi-pulumi/README.md): ReScript bindings for `@pulumi/pulumi`
- [rescript-ssh2](packages/rescript-ssh2/README.md): ReScript bindings for `ssh2`
- [rescript-uuid](packages/rescript-uuid/README.md): ReScript bindings for `uuid`

### Reventless packages

- [reventless-spec](packages/reventless-spec/README.md): types & interface files for the reventless framework
- [reventless](packages/reventless/README.md): Reventless framework (cloud provider agnostic)
- [reventless-aws](packages/reventless-aws/README.md): AWS specifics for the Reventless framework (adapter, pre-configured components, etc.)

## Outdated Packages

The following packages are outdated (located in `./packages_to migrate/*`) and need to be updated:

- [rescript-k6](packages/rescript-k6/README.md): ReScript bindings for k6 - a modern load testing tool for developers and testers
- [rescript-react-test-renderer](packages/rescript-react-test-renderer/README.md): ReScript bindings for react-test-renderer
- [reventless-ci](packages/reventless-ci/README.md): ci tooling for reventless projects (docker image, scripts, ci templates)
- [reventless-ui](packages/reventless-ui/README.md): react component library & core ui for reventless based applications
- [routes](packages/routes/README.md): enables typed routing and bi-directional usage (route & link)

## Setup

This repo uses [npm](https://docs.npmjs.com) and [Lerna](https://lerna.js.org) to manage all the packages.

### Prerequisites

- **Node.js**: Use the version specified in [`.node-version`](.node-version)
- **Node Version Manager**: We recommend [fnm](https://github.com/Schniz/fnm) or [nvm](https://github.com/nvm-sh/nvm)
- **Git**: For version control

### Installation Steps

1. **Configure Node Version Manager** (if using fnm)
   
   Configure fnm to respect `.node-version` files recursively by setting the environment variable:
   ```bash
   export FNM_VERSION_FILE_STRATEGY=recursive
   ```
   Add this to your shell profile (`.bashrc`, `.zshrc`, etc.) to make it permanent.
   
   See [fnm docs](https://github.com/Schniz/fnm/blob/master/docs/commands.md) for more details.

2. **Install Node.js**
   
   ```bash
   fnm install
   fnm use
   ```

3. **Install Dependencies**
   
   From the repository's root directory:
   ```bash
   npm install
   ```
   
   > **Note:** This project uses npm workspaces. Running `npm install` in the root will automatically install dependencies for all packages in the monorepo and link them together. The `lerna bootstrap` command is no longer necessary.

4. **Build All Packages** (optional)
   
   ```bash
   npm run build
   ```

You're all set! Individual packages are located in [`./packages/`](./packages/). Navigate to any package directory to work on it.

