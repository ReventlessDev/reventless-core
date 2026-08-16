# Reventless Documentation

The documentation site for the [Reventless](https://github.com/ReventlessDev/reventless-core)
framework — an event-sourced CQRS framework for serverless business applications,
written in ReScript and deployed with Pulumi.

The site is built with [Docusaurus](https://docusaurus.io/) and published to
[docs.reventless.dev](https://docs.reventless.dev).

## What's covered

The site is organised as five documentation instances, one per audience, in the
order a reader meets them:

- **Why Reventless** (`docs-why`) — evaluating it: the model, what you provide
  and get, deployment options, and how it compares. No code, no internals.
- **Try it** (`docs-tutorials`) — the online-shop example: run it locally, deploy
  it to your own AWS account, test it, then read the code.
- **Build your app** (`docs-app`) — an ordered spine (model, specs, scenarios,
  views, plugins, run and deploy) plus a reference section.
- **Infrastructure** (`docs-infrastructure`) — deploying and operating an
  application, and authoring a provider.
- **Contributing** (`docs-framework`) — framework internals, the runtime
  components an application never writes, and how to extend the framework.

Each instance has its own `sidebars-<name>.js`. Pages that move between them
need a redirect in `docusaurus.config.js` — the build fails on a broken link.

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
`main` publishes to the `docs.reventless.dev` root, with pre-release branches
served under sub-paths.
