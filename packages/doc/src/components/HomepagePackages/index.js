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
    title: 'Developer Tools',
    description: 'Tools to help you build and maintain Reventless applications',
    packages: [
      {
        name: 'reventless-gen',
        description: 'Code generation utilities for scaffolding Reventless projects',
      },
      {
        name: 'reventless-ci',
        description: 'Continuous integration helpers and scripts',
      },
      {
        name: 'reventless-ui',
        description: 'UI components and utilities for building frontends',
      },
      {
        name: 'reventless-contribution-cli',
        description: 'CLI tool for managing contributions and releases',
      },
    ],
  },
  {
    title: 'ReScript Bindings',
    description: 'Type-safe ReScript bindings for essential libraries',
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
      {
        name: 'rescript-uuid',
        description: 'UUID generation bindings',
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
