/**
 * Cognito pre sign-up trigger: registration policy for email addresses.
 *
 * ALLOW_ANY_EMAIL=true opens registration to any address. Otherwise,
 * ALLOWED_EMAIL_DOMAINS is a comma-separated allowlist of exact domains
 * ("infile.com"). Subdomains and look-alikes ("infile.com.evil.io",
 * "mail.infile.com") are rejected. Email ownership is still proven afterwards
 * by Cognito's verification code, so a typed address alone is not enough.
 *
 * Runs for self sign-up and for AdminCreateUser alike. No dependencies: the
 * file is zipped as-is by Terraform.
 */

const allowAnyEmail = () => process.env.ALLOW_ANY_EMAIL === "true";

const allowedDomains = () =>
  (process.env.ALLOWED_EMAIL_DOMAINS ?? "")
    .split(",")
    .map((domain) => domain.trim().toLowerCase())
    .filter(Boolean);

export function emailDomain(email) {
  if (typeof email !== "string") return undefined;
  const normalized = email.trim().toLowerCase();
  const at = normalized.lastIndexOf("@");
  if (at <= 0 || at !== normalized.indexOf("@")) return undefined;
  return normalized.slice(at + 1) || undefined;
}

export function isAllowed(email, domains = allowedDomains()) {
  const domain = emailDomain(email);
  return Boolean(domain) && domains.includes(domain);
}

export const handler = async (event) => {
  const email = event.request?.userAttributes?.email;
  const domains = allowedDomains();

  // Fail closed unless public sign-up was enabled explicitly by Terraform.
  if (!allowAnyEmail() && (domains.length === 0 || !isAllowed(email, domains))) {
    console.warn(
      JSON.stringify({
        message: "Sign-up rejected",
        triggerSource: event.triggerSource,
        domain: emailDomain(email) ?? "invalid",
      }),
    );
    // Cognito shows this text on the sign-up page.
    throw new Error(
      domains.length > 0
        ? `Solo se permiten correos de: ${domains.map((domain) => `@${domain}`).join(", ")}.`
        : "El registro no está habilitado.",
    );
  }

  // Do not auto-confirm or auto-verify: the user must enter the emailed code.
  return event;
};
