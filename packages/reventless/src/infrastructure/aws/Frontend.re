type t;
[@bs.new] [@bs.module "./Frontend"]
external make:
  (
    ~name: string,
    ~path: string,
    ~clientId: string,
    ~userPoolId: string,
    ~region: string,
    ~endpoint: string,
    ~coreEndpoint: string,
    ~identityPoolId: string,
    ~importerBucket: string,
    ~importerBucketRegion: string,
    ~exporterBucket: string,
    ~exporterBucketRegion: string,
    ~csvExporterBucket: string,
    ~csvExporterBucketRegion: string,
    ~domain: string,
    ~certificateArn: string,
    ~opts: Pulumi.CustomResourceOptions.t=?,
    unit
  ) =>
  t =
  "default";
