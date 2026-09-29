import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { emailDomain, handler, isAllowed } from "../src/pre_signup.mjs";

const signUpEvent = (email) => ({
  triggerSource: "PreSignUp_SignUp",
  request: { userAttributes: { email } },
  response: {},
});

beforeEach(() => {
  delete process.env.ALLOW_ANY_EMAIL;
  delete process.env.ALLOWED_EMAIL_DOMAINS;
  vi.spyOn(console, "warn").mockImplementation(() => undefined);
});

afterEach(() => vi.restoreAllMocks());

describe("emailDomain", () => {
  it("extracts the lower-cased domain", () => {
    expect(emailDomain(" Ana@INFILE.com ")).toBe("infile.com");
  });

  it("rejects malformed addresses", () => {
    expect(emailDomain("ana")).toBeUndefined();
    expect(emailDomain("@infile.com")).toBeUndefined();
    expect(emailDomain("ana@")).toBeUndefined();
    expect(emailDomain("a@b@infile.com")).toBeUndefined();
    expect(emailDomain(undefined)).toBeUndefined();
    expect(emailDomain(12)).toBeUndefined();
  });
});

describe("isAllowed", () => {
  it("matches exact domains only", () => {
    const domains = ["infile.com"];
    expect(isAllowed("ana@infile.com", domains)).toBe(true);
    expect(isAllowed("ana@mail.infile.com", domains)).toBe(false);
    expect(isAllowed("ana@infile.com.evil.io", domains)).toBe(false);
  });
});

describe("handler", () => {
  it("fails closed when nothing is configured", async () => {
    await expect(handler(signUpEvent("ana@infile.com"))).rejects.toThrow(
      "El registro no está habilitado.",
    );
  });

  it("accepts any address when ALLOW_ANY_EMAIL is true", async () => {
    process.env.ALLOW_ANY_EMAIL = "true";
    const event = signUpEvent("someone@gmail.com");
    await expect(handler(event)).resolves.toBe(event);
    // Never auto-confirm: the emailed code still proves mailbox ownership.
    expect(event.response.autoConfirmUser).toBeUndefined();
    expect(event.response.autoVerifyEmail).toBeUndefined();
  });

  it("enforces the domain allowlist with a user-facing message", async () => {
    process.env.ALLOWED_EMAIL_DOMAINS = "infile.com, Partner.org";
    await expect(handler(signUpEvent("ana@infile.com"))).resolves.toBeDefined();
    await expect(handler(signUpEvent("ana@partner.org"))).resolves.toBeDefined();
    await expect(handler(signUpEvent("ana@gmail.com"))).rejects.toThrow(
      "Solo se permiten correos de: @infile.com, @partner.org.",
    );
  });

  it("logs only the domain of a rejected address", async () => {
    process.env.ALLOWED_EMAIL_DOMAINS = "infile.com";
    await handler(signUpEvent("secret.person@gmail.com")).catch(() => undefined);
    const logged = console.warn.mock.calls.map((args) => String(args[0])).join("\n");
    expect(logged).toContain('"domain":"gmail.com"');
    expect(logged).not.toContain("secret.person");
  });
});
