// Runs the compiled `Smoke.res` Pulumi program under Pulumi's mock runtime and
// asserts the resource registrations it emits — i.e. that each binding's
// `@scope`/`@new` externals resolve to the right `kubernetes:<group>:<Kind>`
// type token and pass their args through unchanged. No cluster is contacted.
//
// Uses Node's built-in test runner rather than jest: importing the full
// `@pulumi/pulumi` runtime drags in `@pulumi/pulumi/automation`, whose
// transitive `spdx-*` deps jest's resolver cannot follow through pnpm's
// symlinked node_modules. Node resolves them natively.

import { test, describe, before } from 'node:test'
import assert from 'node:assert/strict'
import * as pulumi from '@pulumi/pulumi'

const registered = []

pulumi.runtime.setMocks(
  {
    newResource: args => {
      registered.push({ type: args.type, name: args.name, inputs: args.inputs })
      return { id: `${args.name}_id`, state: args.inputs }
    },
    call: () => ({}),
  },
  'smoke-project',
  'smoke-stack',
  false,
)

// Force the async resource registration to settle before assertions.
const promiseOf = output => new Promise(resolve => output.apply(resolve))

const byType = token => registered.find(r => r.type === token)
const byName = name => registered.find(r => r.name === name)

describe('kubernetes bindings emit the expected Pulumi resources', () => {
  before(async () => {
    const Smoke = await import('./Smoke.res.mjs')
    const ids = Smoke.run()
    await Promise.all([
      promiseOf(ids.deploymentId),
      promiseOf(ids.cronJobId),
      promiseOf(ids.customResourceId),
      promiseOf(ids.releaseId),
    ])
  })

  test('four workload resources are registered (besides the default provider)', () => {
    const nonProvider = registered.filter(r => !r.type.startsWith('pulumi:providers:'))
    assert.ok(nonProvider.length >= 4, `expected >= 4 resources, got ${nonProvider.length}`)
  })

  test('Apps.Deployment -> kubernetes:apps/v1:Deployment with pod spec intact', () => {
    const d = byType('kubernetes:apps/v1:Deployment')
    assert.ok(d, 'no Deployment registered')
    assert.equal(d.inputs.spec.replicas, 2)
    assert.deepEqual(d.inputs.spec.selector.matchLabels, { app: 'web' })
    const container = d.inputs.spec.template.spec.containers[0]
    assert.equal(container.name, 'web')
    assert.equal(container.image, 'nginx:1.27')
    assert.equal(container.ports[0].containerPort, 80)
    assert.deepEqual(container.resources.requests, { cpu: '100m', memory: '128Mi' })
  })

  test('Batch.CronJob -> kubernetes:batch/v1:CronJob with a nested job template', () => {
    const c = byType('kubernetes:batch/v1:CronJob')
    assert.ok(c, 'no CronJob registered')
    assert.equal(c.inputs.spec.schedule, '0 2 * * *')
    const jobContainer = c.inputs.spec.jobTemplate.spec.template.spec.containers[0]
    assert.equal(jobContainer.image, 'busybox:1.36')
    assert.deepEqual(jobContainer.command, ['sh', '-c', 'echo hello'])
  })

  test('ApiExtensions.CustomResource carries the raw apiVersion/kind/spec', () => {
    const cr = byName('my-widget')
    assert.ok(cr, 'no CustomResource registered')
    assert.equal(cr.inputs.apiVersion, 'example.com/v1')
    assert.equal(cr.inputs.kind, 'Widget')
    assert.deepEqual(cr.inputs.spec, { size: 3 })
  })

  test('Helm.Release -> kubernetes:helm.sh/v3:Release with chart + repo', () => {
    const r = byType('kubernetes:helm.sh/v3:Release')
    assert.ok(r, 'no Helm Release registered')
    assert.equal(r.inputs.chart, 'ingress-nginx')
    assert.equal(r.inputs.version, '4.11.0')
    assert.equal(r.inputs.repositoryOpts.repo, 'https://kubernetes.github.io/ingress-nginx')
    assert.equal(r.inputs.values.controller.replicaCount, 2)
  })
})
