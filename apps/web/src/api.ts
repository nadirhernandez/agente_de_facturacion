import type { RuntimeConfig } from "./config";

export type EmbedExperience = "dashboard" | "chat";

interface EmbedResponse {
  embedUrl: string;
  expiresAt: string;
}

/**
 * Requests a short-lived QuickSight embed URL. The Cognito ID token is
 * mandatory: API Gateway rejects unauthenticated requests.
 */
export async function getEmbedUrl(
  config: RuntimeConfig,
  idToken: string,
  experience: EmbedExperience,
): Promise<EmbedResponse> {
  const response = await fetch(`${config.apiBaseUrl}/embed?experience=${experience}`, {
    headers: { authorization: `Bearer ${idToken}` },
  });

  if (response.status === 401 || response.status === 403) {
    throw new Error("Tu sesión no tiene acceso a esta información. Inicia sesión de nuevo.");
  }

  if (!response.ok) {
    throw new Error("No fue posible iniciar la experiencia de análisis.");
  }

  return (await response.json()) as EmbedResponse;
}

export interface FreshnessResponse {
  lastRefreshAt: string | null;
  refreshing: boolean;
  datasets: Array<{ dataSetId: string; lastRefreshAt: string | null; rows: number | null }>;
}

/** Last successful SPICE refresh. SPICE is a copy, so this is the real data age. */
export async function getFreshness(
  config: RuntimeConfig,
  idToken: string,
): Promise<FreshnessResponse> {
  const response = await fetch(`${config.apiBaseUrl}/status`, {
    headers: { authorization: `Bearer ${idToken}` },
  });

  if (!response.ok) {
    throw new Error("No fue posible consultar la actualización de datos.");
  }

  return (await response.json()) as FreshnessResponse;
}

/** "hace 3 minutos", "hace 2 horas", "ayer" — relative to now, in Spanish. */
export function describeAge(isoTimestamp: string | null): string {
  if (!isoTimestamp) return "sin registro de actualización";

  const minutes = Math.floor((Date.now() - new Date(isoTimestamp).getTime()) / 60_000);
  if (minutes < 1) return "actualizado hace un momento";
  if (minutes < 60) return `actualizado hace ${minutes} min`;

  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `actualizado hace ${hours} h`;

  const days = Math.floor(hours / 24);
  if (days === 1) return "actualizado ayer";
  return `actualizado hace ${days} días`;
}
