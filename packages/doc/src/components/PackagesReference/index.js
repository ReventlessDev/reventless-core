import Heading from '@theme/Heading';
import data from '@site/src/data/packages.json';
import styles from './styles.module.css';

function Package({name, description, private: isPrivate}) {
  return (
    <div className={styles.package}>
      <div className={styles.packageHeader}>
        <code className={styles.packageName}>{name}</code>
        {isPrivate && <span className={styles.privateBadge}>private</span>}
      </div>
      <p className={styles.packageDescription}>{description}</p>
    </div>
  );
}

function PackageCategory({title, description, packages}) {
  return (
    <div className={styles.category}>
      <Heading as="h2" className={styles.categoryTitle}>{title}</Heading>
      <p className={styles.categoryDescription}>{description}</p>
      <div className={styles.packageList}>
        {packages.map((pkg) => (
          <Package key={pkg.name} {...pkg} />
        ))}
      </div>
    </div>
  );
}

export default function PackagesReference() {
  return (
    <div className={styles.categoriesGrid}>
      {data.categories.map((category) => (
        <PackageCategory key={category.title} {...category} />
      ))}
    </div>
  );
}
