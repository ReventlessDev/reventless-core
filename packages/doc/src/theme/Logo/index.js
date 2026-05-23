import clsx from 'clsx';
import Link from '@docusaurus/Link';
import useBaseUrl from '@docusaurus/useBaseUrl';
import LogoIcon from '@site/static/img/logo-icon-v2a-sticky.svg';
import styles from './styles.module.css';

// Custom Logo: inline icon + the wordmark as real HTML text.
// Rendering the wordmark as text (instead of baking it into an <img> SVG, which
// can't use webfonts and falls back to a wider OS font) lets the browser reserve
// the exact width — so it never overlaps the first navbar item — and keeps the
// icon↔wordmark spacing a single CSS value.
export default function Logo(props) {
  // The navbar passes imageClassName / titleClassName for the default <img>
  // markup; we render our own, so drop them and keep the rest (className, etc.).
  const {imageClassName, titleClassName, className, ...rest} = props;
  const homeUrl = useBaseUrl('/');
  return (
    <Link
      to={homeUrl}
      className={clsx(className, styles.brand)}
      aria-label="Reventless"
      {...rest}>
      <LogoIcon className={styles.icon} aria-hidden="true" />
      <span className={styles.wordmark} aria-hidden="true">
        <span>r</span>
        <span className={styles.event}>event</span>
        <span>less</span>
      </span>
    </Link>
  );
}
