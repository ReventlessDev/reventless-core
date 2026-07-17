/** A tiny Pulumi program exercising one resource from each of the four
  structurally-distinct binding shapes:

  - `Apps.Deployment`   — nested pod/container spec types,
  - `Batch.CronJob`     — a Job template nested inside a CronJob,
  - `ApiExtensions.CustomResource` — the generic JSON escape hatch,
  - `Helm.Release`      — a chart install.

  `SmokeTest.mjs` runs this under Pulumi mocks and asserts the emitted resource
  shapes. Each `make` external inlines to a real `new k8s.<group>.<Kind>(...)`
  call here, which is what the mock records — hence the program is ReScript,
  not JS.
*/

let input = Pulumi.Input.make

type ids = {
  deploymentId: Pulumi.Output.t<string>,
  cronJobId: Pulumi.Output.t<string>,
  customResourceId: Pulumi.Output.t<string>,
  releaseId: Pulumi.Output.t<string>,
}

let run = (): ids => {
  let labels = dict{"app": "web"}

  let deployment = K8s.Apps.Deployment.make(
    ~name="web",
    ~args={
      metadata: input(K8s.Meta.objectMeta(~name="web", ~labels, ())),
      spec: input({
        replicas: 2,
        selector: {matchLabels: labels},
        template: {
          metadata: K8s.Meta.objectMeta(~labels, ()),
          spec: {
            containers: [
              {
                name: "web",
                image: "nginx:1.27",
                ports: [{containerPort: 80}],
                resources: {
                  requests: dict{"cpu": "100m", "memory": "128Mi"},
                  limits: dict{"cpu": "500m", "memory": "256Mi"},
                },
              },
            ],
          },
        },
      }: K8s.Apps.Deployment.deploymentSpec),
    },
    (),
  )

  let cronJob = K8s.Batch.CronJob.make(
    ~name="nightly",
    ~args={
      metadata: input(K8s.Meta.objectMeta(~name="nightly", ())),
      spec: input({
        schedule: "0 2 * * *",
        jobTemplate: {
          spec: {
            template: {
              spec: {
                restartPolicy: "OnFailure",
                containers: [
                  {
                    name: "batch",
                    image: "busybox:1.36",
                    command: ["sh", "-c", "echo hello"],
                  },
                ],
              },
            },
          },
        },
      }: K8s.Batch.CronJob.cronJobSpec),
    },
    (),
  )

  let customResource = K8s.ApiExtensions.CustomResource.make(
    ~name="my-widget",
    ~args={
      apiVersion: "example.com/v1",
      kind: "Widget",
      metadata: input(K8s.Meta.objectMeta(~name="my-widget", ())),
      spec: input(JSON.Encode.object(Dict.fromArray([("size", JSON.Encode.int(3))]))),
    },
    (),
  )

  let release = K8s.Helm.Release.make(
    ~name="ingress",
    ~args={
      chart: input("ingress-nginx"),
      version: input("4.11.0"),
      namespace: input("ingress"),
      createNamespace: input(true),
      repositoryOpts: input(
        ({repo: "https://kubernetes.github.io/ingress-nginx"}: K8s.Helm.Release.repositoryOpts),
      ),
      values: input(
        JSON.Encode.object(
          Dict.fromArray([
            ("controller", JSON.Encode.object(Dict.fromArray([("replicaCount", JSON.Encode.int(2))]))),
          ]),
        ),
      ),
    },
    (),
  )

  {
    deploymentId: deployment.id,
    cronJobId: cronJob.id,
    customResourceId: customResource.id,
    releaseId: release.id,
  }
}
