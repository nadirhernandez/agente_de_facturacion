export interface RuntimeConfig {
  apiBaseUrl: string;
  cognitoDomain: string;
  cognitoClientId: string;
  region: string;
  /**
   * Agente de Quick al que se fija el chat (scripts/quicksight/sync_agent.py).
   * Opcional: sin él, el chat se abre con el agente por defecto de Quick, igual
   * que antes de existir este campo.
   */
  quickChatAgentId?: string;
}

let cached: RuntimeConfig | undefined;

/**
 * Runtime configuration is published by Terraform as config.json.
 * It contains only public identifiers, never AWS credentials or secrets.
 */
export async function loadConfig(): Promise<RuntimeConfig> {
  if (cached) return cached;

  const response = await fetch("/config.json", { cache: "no-store" });
  if (!response.ok) {
    throw new Error("No se encontró la configuración de la aplicación (config.json).");
  }

  const config = (await response.json()) as RuntimeConfig;
  if (!config.apiBaseUrl || !config.cognitoDomain || !config.cognitoClientId) {
    throw new Error("La configuración de la aplicación está incompleta.");
  }

  cached = { ...config, apiBaseUrl: config.apiBaseUrl.replace(/\/$/, "") };
  return cached;
}
