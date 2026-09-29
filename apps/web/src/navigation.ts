/**
 * Full-page navigation, isolated so tests can observe redirects to Cognito
 * (jsdom does not allow stubbing `window.location.assign`).
 */
export function navigateTo(url: string): void {
  window.location.assign(url);
}
