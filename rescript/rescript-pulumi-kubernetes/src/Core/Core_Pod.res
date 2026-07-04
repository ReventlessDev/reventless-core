/** @pulumi/kubernetes core/v1 pod & container spec types.
  These are `core/v1` types shared by every workload kind (Deployment,
  StatefulSet, Job, CronJob), so they live in `Core` and are referenced from
  `Apps`/`Batch` rather than duplicated.

  Field coverage is intentionally the set consumers routinely set. The long
  tail (securityContext internals, lifecycle hooks, downward-API volumes, …)
  is left as `JSON.t` passthrough (`affinity`, `securityContext`) or is
  reachable via `ApiExtensions.CustomResource` for wholly-untyped specs.
*/

type localObjectReference = {name: string}

// ── env ────────────────────────────────────────────────────────────────────

type configMapKeyRef = {name: string, key: string, optional?: bool}
type secretKeyRef = {name: string, key: string, optional?: bool}
type fieldRef = {fieldPath: string}

/** One of `value` / `valueFrom.*` should be set. `valueFrom` is kept as
  discrete typed refs rather than opaque JSON since these are common. */
type envVarSource = {
  configMapKeyRef?: configMapKeyRef,
  secretKeyRef?: secretKeyRef,
  fieldRef?: fieldRef,
}

type envVar = {
  name: string,
  value?: string,
  valueFrom?: envVarSource,
}

type configMapEnvSource = {name: string, optional?: bool}
type secretEnvSource = {name: string, optional?: bool}

type envFromSource = {
  prefix?: string,
  configMapRef?: configMapEnvSource,
  secretRef?: secretEnvSource,
}

// ── resources ────────────────────────────────────────────────────────────────

/** Quantities keyed by resource name, e.g. `dict{"cpu": "500m", "memory": "256Mi"}`. */
type resourceList = dict<string>
type resourceRequirements = {
  limits?: resourceList,
  requests?: resourceList,
}

// ── ports ────────────────────────────────────────────────────────────────────

type containerPort = {
  containerPort: int,
  name?: string,
  protocol?: string,
  hostPort?: int,
}

// ── probes ───────────────────────────────────────────────────────────────────

type execAction = {command: array<string>}
/** `port` is int-or-string in the API; pass `JSON.Number(...)` or `JSON.String(...)`. */
type httpGetAction = {path?: string, port: JSON.t, scheme?: string}
type tcpSocketAction = {port: JSON.t}

type probe = {
  exec?: execAction,
  httpGet?: httpGetAction,
  tcpSocket?: tcpSocketAction,
  initialDelaySeconds?: int,
  periodSeconds?: int,
  timeoutSeconds?: int,
  successThreshold?: int,
  failureThreshold?: int,
}

// ── volumes & mounts ─────────────────────────────────────────────────────────

type volumeMount = {
  name: string,
  mountPath: string,
  readOnly?: bool,
  subPath?: string,
}

type keyToPath = {key: string, path: string, mode?: int}
type configMapVolumeSource = {
  name: string,
  defaultMode?: int,
  optional?: bool,
  items?: array<keyToPath>,
}
type secretVolumeSource = {
  secretName: string,
  defaultMode?: int,
  optional?: bool,
  items?: array<keyToPath>,
}
type persistentVolumeClaimVolumeSource = {claimName: string, readOnly?: bool}
type emptyDirVolumeSource = {medium?: string, sizeLimit?: string}

type volume = {
  name: string,
  configMap?: configMapVolumeSource,
  secret?: secretVolumeSource,
  persistentVolumeClaim?: persistentVolumeClaimVolumeSource,
  emptyDir?: emptyDirVolumeSource,
}

// ── container ────────────────────────────────────────────────────────────────

type container = {
  name: string,
  image?: string,
  command?: array<string>,
  args?: array<string>,
  workingDir?: string,
  ports?: array<containerPort>,
  env?: array<envVar>,
  envFrom?: array<envFromSource>,
  resources?: resourceRequirements,
  volumeMounts?: array<volumeMount>,
  livenessProbe?: probe,
  readinessProbe?: probe,
  startupProbe?: probe,
  imagePullPolicy?: string,
  /** SecurityContext is left opaque; construct with `JSON.t`. */
  securityContext?: JSON.t,
}

// ── pod ──────────────────────────────────────────────────────────────────────

type toleration = {
  key?: string,
  operator?: string,
  value?: string,
  effect?: string,
  tolerationSeconds?: int,
}

type podSpec = {
  containers: array<container>,
  initContainers?: array<container>,
  volumes?: array<volume>,
  serviceAccountName?: string,
  restartPolicy?: string,
  nodeSelector?: dict<string>,
  tolerations?: array<toleration>,
  terminationGracePeriodSeconds?: int,
  imagePullSecrets?: array<localObjectReference>,
  hostNetwork?: bool,
  /** Affinity is a large, rarely-hand-written tree; kept opaque per plan. */
  affinity?: JSON.t,
  /** SecurityContext (pod-level) left opaque; construct with `JSON.t`. */
  securityContext?: JSON.t,
}

/** The pod template embedded in Deployment/StatefulSet/Job specs. */
type podTemplateSpec = {
  metadata?: Meta.objectMeta,
  spec: podSpec,
}
