"use strict";

const aws = require("@pulumi/aws");
const pulumi = require("@pulumi/pulumi");
const mime = require("mime");
const fs = require("fs");

// Define a component for serving a static website on S3
class Frontend extends pulumi.ComponentResource {

  constructor(bucketName, path, clientId, userPoolId, region, endpoint, coreEndpoint, identityPoolId,
    importerBucket, importerBucketRegion, exporterBucket, exporterBucketRegion,
    csvExporterBucket, csvExporterBucketRegion, domain, certificateArn, opts) {

    super("reventless::frontend", bucketName, {}, opts);

    // Split a domain name into its subdomain and parent domain names.
    // e.g. "www.example.com" => "www", "example.com".
    function getDomainAndSubdomain(domain) {
      const parts = domain.split(".");
      if (parts.length < 2) {
        throw new Error(`No TLD found on ${domain}`);
      }
      // No subdomain, e.g. awesome-website.com.
      if (parts.length === 2) {
        return { subdomain: "", parentDomain: domain };
      }

      const subdomain = parts[0];
      parts.shift();  // Drop first element.
      return {
        subdomain,
        // Trailing "." to canonicalize domain.
        parentDomain: parts.join(".") + ".",
      };
    };

    // For each file in the directory, create an S3 object stored in `siteBucket`
    let allPaths = [path, path + "/assets", path + "/assets/images"];   // NOTE: Add additional paths here!
    let indexJsRegEx = /^Index\.[a-z0-9]+\.js$/;
    let indexHtmlRegEx = /^index\.[a-z0-9]+\.html$/;
    let indexHtml
    let files = [];
    for (let currentPath of allPaths) {
      let dir = (currentPath === path) ? '' : currentPath.replace(path, '') + '/';
      for (let item of fs.readdirSync(currentPath, { withFileTypes: true })) {
        if (item.isFile()) {
          let filePath = require("path").join(currentPath, item.name);
          if (indexJsRegEx.test(item.name)) {
            let fsFilePath = "./" + filePath;
            let indexJsFile = fs.readFileSync(fsFilePath, 'utf8');
            indexJsFile = indexJsFile.replace(/t.clientId="[\w/:\-_.]+"/, "t.clientId=\"" + clientId + "\"");
            indexJsFile = indexJsFile.replace(/t.userPoolId="[\w/:\-_.]+"/, "t.userPoolId=\"" + userPoolId + "\"");
            indexJsFile = indexJsFile.replace(/t.region="[\w/:\-_.]+"/, "t.region=\"" + region + "\"");
            indexJsFile = indexJsFile.replace(/t.endpoint="[\w/:\-_.]+"/, "t.endpoint=\"" + endpoint + "\"");
            indexJsFile = indexJsFile.replace(/Nu="[\w/:\-_.]+"/, "Nu=\"" + coreEndpoint + "\"");
            indexJsFile = indexJsFile.replace(/t.identityPoolId="[\w/:\-_.]+"/, "t.identityPoolId=\"" + identityPoolId + "\"");
            indexJsFile = indexJsFile.replace(/t.importBucket="[\w/:\-_.]+"/, "t.importBucket=\"" + importerBucket + "\"");
            indexJsFile = indexJsFile.replace(/t.importBucketRegion="[\w/:\-_.]+"/, "t.importBucketRegion=\"" + importerBucketRegion + "\"");
            indexJsFile = indexJsFile.replace(/t.exportBucket="[\w/:\-_.]+"/, "t.exportBucket=\"" + exporterBucket + "\"");
            indexJsFile = indexJsFile.replace(/t.exportBucketRegion="[\w/:\-_.]+"/, "t.exportBucketRegion=\"" + exporterBucketRegion + "\"");
            indexJsFile = indexJsFile.replace(/t.csvExportBucket="[\w/:\-_.]+"/, "t.csvExportBucket=\"" + csvExporterBucket + "\"");
            indexJsFile = indexJsFile.replace(/t.csvExportBucketRegion="[\w/:\-_.]+"/, "t.csvExportBucketRegion=\"" + csvExporterBucketRegion + "\"");
            fs.writeFileSync(fsFilePath, indexJsFile, 'utf8');
          }
          else if (indexHtmlRegEx.test(item.name)) {
            indexHtml = dir + item.name;
            let fsFilePath = "./" + filePath;
            let indexHtmlFile = fs.readFileSync(fsFilePath, 'utf8');
            let jsFileRegEx = /Index\.[a-z0-9]+\.js/;
            let jsFile = jsFileRegEx.exec(indexHtmlFile);
            indexHtmlFile = indexHtmlFile.replace(jsFileRegEx, "//" + domain + "/" + jsFile);
            fs.writeFileSync(fsFilePath, indexHtmlFile, 'utf8');
          }
          files.push({ path: filePath, name: dir + item.name });
        }
      }
    }

    // Guard for deployments without an indexDocument
    if (!indexHtml)
      throw new Error("No Index html file found for Frontend");

    // Create a bucket and expose a website index document
    let siteBucket = new aws.s3.Bucket(bucketName, {
      acl: "public-read",
      website: {
        indexDocument: indexHtml,
        errorDocument: indexHtml
      },
    }, { parent: this }); // specify resource parent

    for (let file of files) {
      let object = new aws.s3.BucketObject(file.name, {
        bucket: siteBucket,                               // reference the s3.Bucket object
        source: new pulumi.asset.FileAsset(file.path),     // use FileAsset to point to a file
        contentType: mime.getType(file.path) || undefined, // set the MIME type of the file
      }, { parent: siteBucket }); // specify resource parent
    }

    // logsBucket is an S3 bucket that will contain the CDN's request logs.
    const logsBucket = new aws.s3.Bucket("requestLogs",
      {
        bucket: `${domain.replace(/[\W_]+/g, "-")}-logs`,
        acl: "private",
        forceDestroy: true,
      }, { parent: this });

    const tenMinutes = 60 * 10;

    // distributionArgs configures the CloudFront distribution. Relevant documentation:
    // see: https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/distribution-web-values-specify.html
    // see: https://www.terraform.io/docs/providers/aws/r/cloudfront_distribution.html
    const distributionArgs = {
      enabled: true,
      aliases: [domain],
      origins: [
        {
          originId: siteBucket.arn,
          domainName: siteBucket.websiteEndpoint,
          customOriginConfig: {
            originProtocolPolicy: "http-only",
            httpPort: 80,
            httpsPort: 443,
            originSslProtocols: ["TLSv1.2"],
          },
        },
      ],
      defaultRootObject: indexHtml,
      defaultCacheBehavior: {
        targetOriginId: siteBucket.arn,
        viewerProtocolPolicy: "redirect-to-https",
        allowedMethods: ["GET", "HEAD", "OPTIONS"],
        cachedMethods: ["GET", "HEAD", "OPTIONS"],
        forwardedValues: {
          cookies: { forward: "none" },
          queryString: false,
        },
        minTtl: 0,
        defaultTtl: tenMinutes,
        maxTtl: tenMinutes,
      },
      priceClass: "PriceClass_100",
      customErrorResponses: [
        { errorCode: 404, responseCode: 200, responsePagePath: "/" + indexHtml },
      ],

      restrictions: {
        geoRestriction: {
          restrictionType: "none",
        },
      },

      viewerCertificate: {
        acmCertificateArn: certificateArn,
        sslSupportMethod: "sni-only",
      },

      loggingConfig: {
        bucket: logsBucket.bucketDomainName,
        includeCookies: false,
        prefix: `${domain}/`,
      },
    };
    const cdn = new aws.cloudfront.Distribution("cdn", distributionArgs, { parent: this });

    // Creates a new Route53 DNS record pointing the domain to the CloudFront distribution.
    function createAliasRecord(targetDomain, distribution) {
      const domainParts = getDomainAndSubdomain(targetDomain);
      const hostedZone = aws.route53.getZone({ name: domainParts.parentDomain });
      return new aws.route53.Record(
        targetDomain,
        {
          name: domainParts.subdomain,
          zoneId: hostedZone.then(hostedZone => hostedZone.zoneId),
          type: "A",
          aliases: [
            {
              name: distribution.domainName,
              zoneId: distribution.hostedZoneId,
              evaluateTargetHealth: true,
            },
          ],
        }, { parent: this });
    }

    const aRecord = createAliasRecord(domain, cdn);

    // Set the access policy for the bucket so all objects are readable
    let bucketPolicy = new aws.s3.BucketPolicy("bucketPolicy", {
      bucket: siteBucket.bucket,
      policy: siteBucket.bucket.apply(this.publicReadPolicyForBucket),
    }, { parent: siteBucket }); // specify resource parent

    /* OLD:
    this.bucketName = siteBucket.bucket;
    this.websiteUrl = siteBucket.websiteEndpoint;

    // Register output properties for this component
    this.registerOutputs({
      bucketName: this.bucketName,
      websiteUrl: this.websiteUrl,
    });
  */

    this.contentBucketUri = pulumi.interpolate`s3://${siteBucket.bucket}`;
    this.contentBucketWebsiteEndpoint = siteBucket.websiteEndpoint;
    this.cloudFrontDomain = cdn.domainName;
    this.targetDomainEndpoint = `https://${domain}/`;

    this.registerOutputs({
      contentBucketUri: this.contentBucketUri,
      contentBucketWebsiteEndpoint: this.contentBucketWebsiteEndpoint,
      cloudFrontDomain: this.cloudFrontDomain,
      targetDomain: this.targetDomain,
    });
  }

  publicReadPolicyForBucket(bucketName) {
    return JSON.stringify({
      Version: "2012-10-17",
      Statement: [{
        Effect: "Allow",
        Principal: "*",
        Action: [
          "s3:GetObject"
        ],
        Resource: [
          `arn:aws:s3:::${bucketName}/*` // policy refers to bucket name explicitly
        ]
      }]
    });
  }

}

exports.default = Frontend;
