import { Icon } from "./Icon";

export const PRODUCT_NAME = "INsight";
export const VENDOR_NAME = "INFILE";
export const TAGLINE = "Insight desde adentro de su facturación.";

/**
 * Product wordmark. "IN" is the INFILE prefix and always carries the accent
 * color; "sight" follows the surrounding text color. Never written InSight,
 * In-Sight or with both halves in the same color.
 */
export function Wordmark({
  size = "md",
  withVendor = true,
}: {
  size?: "sm" | "md" | "lg";
  withVendor?: boolean;
}) {
  return (
    <span className={`wordmark wordmark-${size}`}>
      <span className="wordmark-name" aria-label={PRODUCT_NAME}>
        <b aria-hidden="true">IN</b>
        <span aria-hidden="true">sight</span>
      </span>
      {withVendor && <small className="wordmark-vendor">by {VENDOR_NAME}</small>}
    </span>
  );
}

/** Initials for the client mark when there is no logo: "Empresa Inteligente S.A." → "EI". */
export function initialsOf(name: string): string {
  const words = name
    .replace(/\b(s\.?a\.?|s\.?r\.?l\.?|ltda\.?|inc\.?|de|del|la|los|las|y|&)\b/gi, " ")
    .split(/\s+/)
    .filter(Boolean);
  const letters = words
    .slice(0, 2)
    .map((word) => word.replace(/[^\p{L}\p{N}]/gu, "")[0]?.toUpperCase() ?? "")
    .join("");
  return (
    letters ||
    name
      .replace(/[^\p{L}\p{N}]/gu, "")
      .slice(0, 2)
      .toUpperCase()
  );
}

/**
 * The client owns the workspace: their name goes large, their logo if they
 * have one. Falls back to a generic label when the tenant has not set one.
 */
export function ClientIdentity({
  name,
  logoUrl,
  compact = false,
}: {
  name?: string;
  logoUrl?: string;
  compact?: boolean;
}) {
  const label = name ?? "Espacio de trabajo";
  return (
    <div className={compact ? "client-identity compact" : "client-identity"}>
      {logoUrl ? (
        <img alt="" className="client-logo" src={logoUrl} />
      ) : (
        <span aria-hidden="true" className="client-mark">
          {name ? initialsOf(name) : <Icon name="dashboard" size={16} />}
        </span>
      )}
      <span className="client-name">{label}</span>
    </div>
  );
}
