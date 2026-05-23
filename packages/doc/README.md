# Reventless Documentation

The documentation site for the [Reventless](https://github.com/ReventlessDev/reventless-core)
framework — an event-sourced CQRS framework for serverless business applications,
written in ReScript and deployed with Pulumi.

The site is built with [Docusaurus](https://docusaurus.io/) and published to
[reventless.dev](https://reventless.dev).

## What's covered

The site is organised around four documentation instances, one per audience:

- **Introduction** — what Reventless is and which path to take.
- **Tutorial** — the online-shop example, end to end: understand it, run it
  locally, deploy it to AWS, and test it.
- **App Guide** — building your own application: plugins, aggregates, read
  models, DCB slices, the GraphQL API, and the host-shell UI.
- **Infrastructure** — the AWS adapters, Pulumi deployment, live updates, and
  pointing a deployed app at your own domain.
- **Contributing** — framework internals and how to extend the framework.

## Local development

```bash
pnpm install
pnpm run start   # dev server with hot reload
```

Most changes are reflected live without restarting the server.

## Build

```bash
pnpm run build   # static site into ./build
pnpm run serve   # serve the built site locally
```

## Deployment

The site is built and deployed by CI (`.github/workflows/deploy-docs.yml`):
`main` publishes to the `reventless.dev` root, with pre-release branches served
under sub-paths.
