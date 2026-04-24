import clsx from 'clsx';
import Heading from '@theme/Heading';
import Link from '@docusaurus/Link';
import styles from './styles.module.css';

const PackageCategories = [
  {
    title: 'Core Framework',
    description: 'The main packages that make up the Reventless framework',
    packages: [
      {
        name: 'reventless',
        description: 'Core framework with provider-agnostic components: Aggregates, ReadModels, Plugins, and adapters',
      },
      {
        name: 'reventless-spec',
        description: 'Type specifications and interfaces for aggregates, read models, and plugins',
      },
      {
        name: 'reventless-aws',
        description: 'AWS-specific implementations: DynamoDB, Lambda, SQS, SNS, and S3 adapters',
      },
    ],
  },
  {
    title: 'Build & Documentation',
    description: 'Tools to help you build and document Reventless applications',
    packages: [
      {
        name: 'doc',
        description: 'Docusaurus-based documentation site for the framework',
      },
    ],
  },
  {
    title: 'Infrastructure',
    description: 'Deployment and infrastructure packages',
    packages: [
      {
        name: 'aws-lambda-layer',
        description: 'Pre-built AWS Lambda layer with Reventless dependencies',
      },
    ],
  },
  {
    title: 'ReScript - AWS & Infrastructure',
    description: 'ReScript bindings for AWS services and infrastructure-as-code',
    packages: [
      {
        name: 'rescript-aws-sdk',
        description: 'Bindings for AWS SDK (DynamoDB, S3, SQS, SNS, Lambda)',
      },
      {
        name: 'rescript-pulumi-pulumi',
        description: 'Bindings for Pulumi core infrastructure-as-code',
      },
      {
        name: 'rescript-pulumi-aws',
        description: 'Bindings for Pulumi AWS provider',
      },
    ],
  },
  {
    title: 'ReScript - Node.js',
    description: 'ReScript bindings for Node.js core libraries',
    packages: [
      {
        name: 'rescript-node-streams',
        description: 'Bindings for Node.js streams API',
      },
      {
        name: 'rescript-node-zlib',
        description: 'Bindings for Node.js zlib compression library',
      },
    ],
  },
  {
    title: 'ReScript - Utilities',
    description: 'ReScript bindings for common utility libraries',
    packages: [
      {
        name: 'rescript-uuid',
        description: 'UUID generation bindings',
      },
      {
        name: 'rescript-fast-csv',
        description: 'Bindings for fast-csv library for CSV parsing and formatting',
      },
      {
        name: 'rescript-hash-object',
        description: 'Bindings for object hashing utilities',
      },
      {
        name: 'rescript-moment',
        description: 'Bindings for Moment.js date/time library (shared with UI repo)',
      },
      {
        name: 'rescript-ssh2',
        description: 'Bindings for SSH2 client library',
      },
    ],
  }
];

function Package({name, description}) {
  return (
    <div className={styles.package}>
      <code className={styles.packageName}>{name}</code>
      <p className={styles.packageDescription}>{description}</p>
    </div>
  );
}

function PackageCategory({title, description, packages}) {
  return (
    <div className={styles.category}>
      <Heading as="h3" className={styles.categoryTitle}>{title}</Heading>
      <p className={styles.categoryDescription}>{description}</p>
      <div className={styles.packageList}>
        {packages.map((pkg, idx) => (
          <Package key={idx} {...pkg} />
        ))}
      </div>
    </div>
  );
}

export default function HomepagePackages() {
  return (
    <section className={styles.packages}>
      <div className="container">
        <Heading as="h2" className={styles.sectionTitle}>
          Monorepo Packages
        </Heading>
        <p className={styles.sectionDescription}>
          Reventless is organized as a monorepo with focused, composable packages
        </p>
        <div className={styles.categoriesGrid}>
          {PackageCategories.map((category, idx) => (
            <PackageCategory key={idx} {...category} />
          ))}
        </div>
      </div>
    </section>
  );
}
