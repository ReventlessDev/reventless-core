import clsx from 'clsx';
import Heading from '@theme/Heading';
import styles from './styles.module.css';

const FeatureList = [
  {
    title: 'Spec-Driven',
    icon: '📐',
    description: (
      <>
        Your types are the spec. A single annotation turns events, commands, and
        read models into database schemas, GraphQL and MCP APIs, and AWS
        infrastructure — generated and wired for you. Change the spec, regenerate
        the system: no glue code, no drift between layers.
      </>
    ),
  },
  {
    title: 'AI-Native',
    icon: '🤖',
    description: (
      <>
        Spec-driven and AI-assisted development are a natural pairing. Strict type
        contracts make Reventless an excellent target for LLM code generation —
        the compiler validates every slice, decider, and projection on the spot.
        And event-sourced histories are an ideal structured dataset for analytics
        and AI/ML.
      </>
    ),
  },
  {
    title: 'Slice-Based Architecture',
    icon: '🧩',
    description: (
      <>
        Event modeling with Dynamic Consistency Boundary (DCB) patterns. Compose
        systems from independent, vertical slices that own their commands, events,
        and read models and communicate only through events — so teams develop,
        test, and deploy them independently.
      </>
    ),
  },
  {
    title: 'Zero Boilerplate',
    icon: '⚡',
    description: (
      <>
        Built in ReScript. Algebraic data types and pattern matching model your
        domain directly, and the compiler enforces exhaustive handling. Concise,
        type-safe code with no manual schema files and nothing to keep in sync.
      </>
    ),
  },
  {
    title: 'Serverless, Self-Hosted',
    icon: '☁️',
    description: (
      <>
        Open-source software you deploy into your own AWS account — not a hosted
        SaaS. Ships with AWS and in-memory providers today, with more cloud
        targets planned. Serverless means you pay only for what you use, with no
        idle infrastructure.
      </>
    ),
  },
  {
    title: 'Production-Ready',
    icon: '🚀',
    description: (
      <>
        In production in the financial industry since 2019. Built on a typed effect
        system: typed error handling, automatic retries with backoff, and streaming
        throughout — for efficient projection rebuilds and event replay at scale.
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
