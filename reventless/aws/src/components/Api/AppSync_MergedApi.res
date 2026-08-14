// AppSync_MergedApi — merged-API construction for the push-free composition
// path (docs/plans/done/merged-api-push-free-composition.md, Phase 3).
//
// A merged API carries no schema of its own: source APIs contribute theirs via
// SourceApiAssociation and AWS composes the merged endpoint. The platform
// stack creates the merged API(s) plus the association(s) for its own
// source(s) (the admin/base canonical source); plugin stacks associate their
// source APIs against the exported merged-API ARN (Phase 4).

open PulumiAws

// ── Primary-auth contract ───────────────────────────────────────────────────
// A merged API and every associated source API must share the same PRIMARY
// authentication mode (AWS rejects incompatible associations). The platform
// exports the merged API's mode via StackReference (`mergedApiPrimaryAuth`);
// stacks creating a source API assert against it before associating.

let authenticationTypeName = (t: AppSync.GraphQLApi.authenticationType): string =>
  switch t {
  | API_KEY => "API_KEY"
  | AWS_IAM => "AWS_IAM"
  | AMAZON_COGNITO_USER_POOLS => "AMAZON_COGNITO_USER_POOLS"
  | OPENID_CONNECT => "OPENID_CONNECT"
  }

// The merged APIs share the platform-wide primary mode (Cognito primary,
// IAM secondary) — same shape the Phase-0 spike validated end-to-end.
let primaryAuthMode = authenticationTypeName(AppSync_Adapter.primaryAuthenticationType)

let assertCompatiblePrimaryAuth = (~sourceMode: string, ~mergedMode: string): unit =>
  if sourceMode != mergedMode {
    failwith(
      `Merged-API primary-auth mismatch: the source API uses ${sourceMode} but the merged API ` ++
      `expects ${mergedMode}. A source API must share the merged API's primary authentication ` ++
      `mode — align the source API's authenticationType with the platform's ` ++ `\`mergedApiPrimaryAuth\` export before associating.`,
    )
  }

// ── Merged API + execution role ─────────────────────────────────────────────

type t = {
  api: Pulumi.Output.t<AppSync.GraphQLApi.t>,
  executionRole: IAM.Role.t,
}

let make = (~name: string, ~opts: Pulumi.ComponentResource.options): t => {
  let customOpts: Pulumi.CustomResourceOptions.t = {
    parent: ?opts.parent,
  }

  // Execution role AWS assumes to proxy merged-endpoint requests to the source
  // APIs (appsync:SourceGraphQL) and to run schema merges
  // (appsync:StartSchemaMerge — required for MANUAL_MERGE, harmless under
  // AUTO_MERGE). Source APIs associate later from independent plugin stacks,
  // so their ARNs cannot be enumerated here — the policy stays unscoped.
  let executionRole = IAM.Role.make(
    ~name=`${name}-merge-exec-role`,
    ~args={
      assumeRolePolicy: `{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"appsync.amazonaws.com"},"Action":"sts:AssumeRole"}]}`->Pulumi.Input.make,
      tags: AWS.Tags.make(
        ~name=`${name}-merge-exec-role`,
        ~kind=ReventlessCore.ComponentType.Platform,
        ~role=Identity,
        ~scope=Platform,
      ),
    },
    ~opts=Some(customOpts),
  )
  let _ = {
    open PolicyDocument
    IAM.RolePolicy.make(
      ~name=`${name}-merge-exec-policy`,
      ~args={
        policy: PolicyDocument.make(
          ~id=`${name}-merge-exec-policy`,
          ~statements=[
            {
              sid: "AllowSourceGraphQLAndMerge",
              effect: Allow,
              actions: Actions(["appsync:SourceGraphQL", "appsync:StartSchemaMerge"]),
              resources: AllResources,
            },
          ],
        )
        ->PolicyDocument.toJsonString
        ->Pulumi.Input.make,
        role: executionRole.id->Pulumi.Output.asInput,
      },
      ~opts=customOpts,
    )
  }

  // Same auth shape as the source APIs (AppSync_Adapter.makeApiResource):
  // Cognito primary + AWS_IAM secondary. Per-field multi-auth directives on
  // the source schemas survive the merge verbatim (Phase-0 finding 4).
  let authConfigOut = Auth_Cognito.make(~name=`${name}-auth`)
  let userPoolConfigOut =
    authConfigOut->Pulumi.Output.apply((
      c: Auth_Cognito.authConfig,
    ): AppSync.GraphQLApi.userPoolConfig => {
      userPoolId: c.userPoolId,
      awsRegion: c.region,
      defaultAction: AppSync.GraphQLApi.DENY,
    })

  let mergedApi = AppSync.GraphQLApi.make(
    ~name,
    ~args={
      authenticationType: AppSync_Adapter.primaryAuthenticationType->Pulumi.Input.make,
      userPoolConfig: userPoolConfigOut->Pulumi.Output.asInput,
      additionalAuthenticationProviders: [
        (
          {
            authenticationType: AppSync.GraphQLApi.AWS_IAM->Pulumi.Input.make,
          }: AppSync.GraphQLApi.additionalAuthenticationProvider
        )->Pulumi.Input.make,
      ]->Pulumi.Input.make,
      apiType: AppSync.GraphQLApi.MERGED->Pulumi.Input.make,
      mergedApiExecutionRoleArn: executionRole.arn->Pulumi.Output.asInput,
      tags: AWS.Tags.make(
        ~name,
        ~kind=ReventlessCore.ComponentType.Platform,
        ~role=Api,
        ~scope=Platform,
      ),
    },
    ~opts=Some(customOpts),
  )

  {api: mergedApi->Pulumi.Output.make, executionRole}
}

// ── Source association ──────────────────────────────────────────────────────

/** Associate a source API with the merged API under AUTO_MERGE. AWS
    serializes association CREATES per merged API (409
    ConcurrentModificationException). This platform-stack form stays on the
    classic provider: the platform stack creates all its own associations
    (admin + base) sequentially within one program, so they never race. The
    cross-stack race is on the plugin-stack `associateSourceWithMergedArn`
    path, which uses the retrying provider (Phase 4). */
let associateSource = (
  ~name: string,
  ~mergedApi: t,
  ~sourceApi: Pulumi.Output.t<AppSync.GraphQLApi.t>,
  ~opts: Pulumi.ComponentResource.options,
): AppSync.SourceApiAssociation.t => {
  let customOpts: Pulumi.CustomResourceOptions.t = {
    parent: ?opts.parent,
  }
  AppSync.SourceApiAssociation.make(
    ~name,
    ~args={
      mergedApiId: mergedApi.api
      ->Pulumi.Output.flatMap((a: AppSync.GraphQLApi.t) => a.id)
      ->Pulumi.Output.asInput,
      sourceApiId: sourceApi
      ->Pulumi.Output.flatMap((a: AppSync.GraphQLApi.t) => a.id)
      ->Pulumi.Output.asInput,
      sourceApiAssociationConfigs: [
        (
          {
            mergeType: AppSync.SourceApiAssociation.AUTO_MERGE->Pulumi.Input.make,
          }: AppSync.SourceApiAssociation.sourceApiAssociationConfig
        )->Pulumi.Input.make,
      ]->Pulumi.Input.make,
    },
    ~opts=Some(customOpts),
  )
}

/** Associate a source API against a merged API referenced by ARN — the
    plugin-stack form, where the merged API is not a resource in this stack
    but the platform's `domainMergedApiArn` / `platformMergedApiArn`
    StackReference export.

    Concurrent first-time plugin deploys race here: AWS serializes association
    writes per merged API and 409s (`ConcurrentModificationException`). This
    goes through `AppSync_SourceApiAssociation_Retrying`, a dynamic provider
    that retries the 409 with backoff (Phase 4), so plugin stacks can deploy in
    parallel without a CI-level serialization. The returned resource keeps the
    `PulumiAws.AppSync.SourceApiAssociation.t` shape, so `mergeStatusGateWith`
    still waits for MERGE_SUCCESS on `.associationId` unchanged. */
let associateSourceWithMergedArn = (
  ~name: string,
  ~mergedApiArn: Pulumi.Output.t<string>,
  ~sourceApi: Pulumi.Output.t<AppSync.GraphQLApi.t>,
  ~opts: Pulumi.ComponentResource.options,
): AppSync.SourceApiAssociation.t => {
  let customOpts: Pulumi.CustomResourceOptions.t = {
    parent: ?opts.parent,
  }
  AppSync_SourceApiAssociation_Retrying.make(
    ~name,
    ~props={
      mergedApiIdentifier: mergedApiArn->Pulumi.Output.asInput,
      sourceApiIdentifier: sourceApi
      ->Pulumi.Output.flatMap((a: AppSync.GraphQLApi.t) => a.id)
      ->Pulumi.Output.asInput,
      mergeType: "AUTO_MERGE"->Pulumi.Input.make,
    },
    ~opts=Some(customOpts),
  )
}

/** Deploy-time merge gate: resolves once the association reports
    MERGE_SUCCESS, fails the deploy loudly (with AWS's status detail) on
    MERGE_FAILED. Fold the returned Output into an exported value so it is
    consumed — a MERGE_FAILED then fails `pulumi up` instead of silently
    serving the last-good merged schema (Phase-0 operational finding).
    `mergedApiIdentifier` accepts the merged API's id or ARN. */
let mergeStatusGateWith = (
  ~mergedApiIdentifier: Pulumi.Output.t<string>,
  ~association: AppSync.SourceApiAssociation.t,
): Pulumi.Output.t<unit> =>
  (mergedApiIdentifier, association.associationId)
  ->Pulumi.Output.all2
  ->Pulumi.Output.flatMap(((identifier, associationId)) =>
    AppSync_Adapter.waitForMergeSuccess(
      AppSync_Adapter.getClient(),
      ~associationId,
      ~mergedApiIdentifier=identifier,
    )->Pulumi.Output.fromPromise
  )

let mergeStatusGate = (
  ~mergedApi: t,
  ~association: AppSync.SourceApiAssociation.t,
): Pulumi.Output.t<unit> =>
  mergeStatusGateWith(
    ~mergedApiIdentifier=mergedApi.api->Pulumi.Output.flatMap((a: AppSync.GraphQLApi.t) => a.id),
    ~association,
  )
