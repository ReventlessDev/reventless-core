import clsx from 'clsx';
import Heading from '@theme/Heading';
import styles from './styles.module.css';

const FeatureList = [
  {
    title: 'Event-Sourced Architecture',
    icon: '📦',
    description: (
      <>
        Built on Domain-Driven Design principles with Event Sourcing and CQRS.
        Every state change is captured as an immutable event, providing full
        auditability and the ability to rebuild state at any point in time.
      </>
    ),
  },
  {
    title: 'Serverless First',
    icon: '☁️',
    description: (
      <>
        Designed for serverless infrastructure from the ground up. Pay only for
        what you use with automatic scaling. Deploy to AWS Lambda with DynamoDB,
        SQS, SNS, and S3 out of the box.
      </>
    ),
  },
  {
    title: 'Type-Safe ReScript',
    icon: '🔒',
    description: (
      <>
        Written in ReScript for end-to-end type safety across your entire stack.
        Catch errors at compile time, enjoy great refactoring support, and
        benefit from a functional programming paradigm.
      </>
    ),
  },
  {
    title: 'Infrastructure as Code',
    icon: '🏗️',
    description: (
      <>
        Powered by Pulumi for declarative infrastructure. Define your entire
        cloud architecture in code alongside your application logic. No manual
        cloud configuration required.
      </>
    ),
  },
  {
    title: 'Focus on Business Logic',
    icon: '💼',
    description: (
      <>
        The framework handles the complex infrastructure concerns so you can
        focus on what matters: your domain logic. Define aggregates, commands,
        and events with minimal boilerplate.
      </>
    ),
  },
  {
    title: 'Production Ready',
    icon: '🚀',
    description: (
      <>
        Battle-tested in production for financial industry applications since
        2019. Proven patterns for reliability, scalability, and maintainability
        in enterprise environments.
      </>
    ),
  },
];

function Feature({icon, title, description}) {
  return (
    <div className={clsx('col col--4')}>
      <div className={styles.featureCard}>
        <div className={styles.featureIcon}>{icon}</div>
        <Heading as="h3" className={styles.featureTitle}>{title}</Heading>
        <p className={styles.featureDescription}>{description}</p>
      </div>
    </div>
  );
}

export default function HomepageFeatures() {
  return (
    <section className={styles.features}>
      <div className="container">
        <Heading as="h2" className={styles.sectionTitle}>
          Why Reventless?
        </Heading>
        <div className="row">
          {FeatureList.map((props, idx) => (
            <Feature key={idx} {...props} />
          ))}
        </div>
      </div>
    </section>
  );
}
