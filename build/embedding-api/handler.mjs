import {
  GenerateEmbedUrlForRegisteredUserCommand,
  ListIngestionsCommand,
  ListUsersCommand,
  QuickSightClient,
} from "@aws-sdk/client-quicksight";

const client = new QuickSightClient({});

const required = (name) => {
  const value = process.env[name];
  if (!value) throw new Error(`Missing required environment variable: ${name}`);
  return value;
};

const allowedDomains = () =>
  required("ALLOWED_DOMAINS")
    .split(",")
    .map((domain) => domain.trim())
    .filter(Boolean);

const response = (statusCode, body) => ({
  statusCode,
  headers: {
    "content-type": "application/json",
    "access-control-allow-origin": process.env.CORS_ORIGIN ?? "http://localhost:5173",
    "access-control-allow-methods": "GET,OPTIONS",
    "cache-control": "no-store",
  },
  body: JSON.stringify(body),
});

/** Cached email -> QuickSight user ARN lookups for the lifetime of the container. */
const userArnCache = new Map();

/**
 * Resolves the QuickSight identity for the authenticated caller.
 *
 * Each person should map to their own QuickSight user so that row-level
 * security and author/reader permissions apply per user. When no match exists
 * the request is rejected, unless FALLBACK_QUICKSIGHT_USER_ARN is configured
 * for single-tenant development.
 */
async function resolveQuickSightUserArn(email) {
  if (!email) return process.env.FALLBACK_QUICKSIGHT_USER_ARN;
  if (userArnCache.has(email)) return userArnCache.get(email);

  const accountId = required("QUICKSIGHT_ACCOUNT_ID");
  let nextToken;

  do {
    const page = await client.send(
      new ListUsersCommand({
        AwsAccountId: accountId,
        Namespace: "default",
        MaxResults: 100,
        NextToken: nextToken,
      }),
    );

    const match = page.UserList?.find(
      (user) => user.Email?.toLowerCase() === email.toLowerCase() && user.Active !== false,
    );

    if (match?.Arn) {
      userArnCache.set(email, match.Arn);
      return match.Arn;
    }

    nextToken = page.NextToken;
  } while (nextToken);

  const fallback = process.env.FALLBACK_QUICKSIGHT_USER_ARN;
  if (fallback) {
    console.warn(
      JSON.stringify({
        message: "No QuickSight user matched the caller; using development fallback identity",
        email,
      }),
    );
  }
  return fallback;
}

function experienceConfigurationFor(experience) {
  switch (experience) {
    case "dashboard":
      return {
        Dashboard: {
          InitialDashboardId: required("DASHBOARD_ID"),
          FeatureConfigurations: {
            Bookmarks: { Enabled: false },
            SharedView: { Enabled: false },
            StatePersistence: { Enabled: true },
          },
        },
      };
    case "chat":
      return { QuickChat: {} };
    default:
      return undefined;
  }
}

/**
 * Last successful SPICE ingestion per dataset. This is what the UI should show:
 * SPICE is a copy, so "up to date" only means "as of the last refresh".
 */
async function datasetFreshness() {
  const accountId = required("QUICKSIGHT_ACCOUNT_ID");
  const datasetIds = required("DATA_SET_IDS").split(",").map((id) => id.trim()).filter(Boolean);

  const datasets = await Promise.all(
    datasetIds.map(async (dataSetId) => {
      try {
        const page = await client.send(
          new ListIngestionsCommand({ AwsAccountId: accountId, DataSetId: dataSetId, MaxResults: 20 }),
        );

        const completed = page.Ingestions?.find(
          (ingestion) => ingestion.IngestionStatus === "COMPLETED",
        );

        return {
          dataSetId,
          lastRefreshAt: completed?.CreatedTime ? new Date(completed.CreatedTime).toISOString() : null,
          rows: completed?.RowInfo?.RowsIngested ?? null,
          running: page.Ingestions?.some((ingestion) =>
            ["INITIALIZED", "QUEUED", "RUNNING"].includes(ingestion.IngestionStatus),
          ) ?? false,
        };
      } catch (error) {
        console.warn(JSON.stringify({ message: "Could not read ingestions", dataSetId, error: String(error) }));
        return { dataSetId, lastRefreshAt: null, rows: null, running: false };
      }
    }),
  );

  const timestamps = datasets.map((item) => item.lastRefreshAt).filter(Boolean).sort();

  return {
    // The dashboard is only as fresh as its stalest dataset.
    lastRefreshAt: timestamps.length > 0 ? timestamps[0] : null,
    refreshing: datasets.some((item) => item.running),
    datasets,
  };
}

export const handler = async (event) => {
  if (event.requestContext?.http?.method === "OPTIONS") {
    return response(204, {});
  }

  const path = event.requestContext?.http?.path ?? event.rawPath ?? "";
  if (path.endsWith("/status")) {
    try {
      return response(200, await datasetFreshness());
    } catch (error) {
      console.error("Failed to read dataset freshness", error);
      return response(500, { message: "No fue posible consultar la actualización de datos." });
    }
  }

  const experience = event.queryStringParameters?.experience;
  const experienceConfiguration = experienceConfigurationFor(experience);

  if (!experienceConfiguration) {
    return response(400, { message: "experience must be dashboard or chat" });
  }

  const claims = event.requestContext?.authorizer?.jwt?.claims ?? {};
  const email = typeof claims.email === "string" ? claims.email : undefined;

  try {
    const userArn = await resolveQuickSightUserArn(email);
    if (!userArn) {
      return response(403, {
        message: "Tu cuenta aún no tiene acceso a los tableros. Contacta al administrador.",
      });
    }

    const result = await client.send(
      new GenerateEmbedUrlForRegisteredUserCommand({
        AwsAccountId: required("QUICKSIGHT_ACCOUNT_ID"),
        UserArn: userArn,
        ExperienceConfiguration: experienceConfiguration,
        AllowedDomains: allowedDomains(),
        SessionLifetimeInMinutes: 60,
      }),
    );

    return response(200, {
      embedUrl: result.EmbedUrl,
      expiresAt: new Date(Date.now() + 60 * 60 * 1000).toISOString(),
    });
  } catch (error) {
    console.error("Failed to generate QuickSight embed URL", error);
    return response(500, { message: "No fue posible iniciar la experiencia de análisis." });
  }
};
