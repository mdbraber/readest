export interface PublicReadestClientConfig {
  apiBaseUrl?: string | undefined;
  supabaseUrl?: string | undefined;
  supabaseAnonKey?: string | undefined;
  objectStorageType?: string | undefined;
  storageFixedQuota?: number | undefined;
  translationFixedQuota?: number | undefined;
}

export interface CustomServerConfig {
  serverBaseUrl: string;
  apiBaseUrl: string;
  supabaseUrl?: string | undefined;
  supabaseAnonKey?: string | undefined;
  fetchedAt: number;
}

interface StorageAdapter {
  getItem: (key: string) => string | null;
  setItem: (key: string, value: string) => void;
  removeItem: (key: string) => void;
}

export type CustomServerConfigErrorCode =
  | 'invalid-url'
  | 'insecure-http'
  | 'server-not-reachable'
  | 'invalid-config'
  | 'missing-supabase-config'
  | 'dangerous-secret';

export class CustomServerConfigError extends Error {
  code: CustomServerConfigErrorCode;

  constructor(code: CustomServerConfigErrorCode, message: string) {
    super(message);
    this.name = 'CustomServerConfigError';
    this.code = code;
  }
}

interface NormalizeUrlOptions {
  allowInsecureHttp?: boolean;
}

interface ResolveCustomServerConfigOptions extends NormalizeUrlOptions {
  fetchImpl?: typeof fetch;
  requireSupabase?: boolean;
  now?: () => number;
}

interface SaveCustomServerConfigOptions {
  resetSession?: boolean;
}

const CUSTOM_SERVER_CONFIG_KEY = 'readest_custom_server_config_v1';

const PUBLIC_CONFIG_PATHS = [
  '/.well-known/readest-client-config.json',
  '/api/public/runtime-config',
] as const;

const DANGEROUS_SECRET_FIELDS = [
  'service_role',
  'jwt_secret',
  'postgres_password',
  'database_url',
  's3_secret',
  'aws_secret_access_key',
  'private_key',
] as const;

let storageAdapter: StorageAdapter | null = null;

const getStorageAdapter = (): StorageAdapter | null => {
  if (storageAdapter) return storageAdapter;
  if (typeof window === 'undefined') return null;
  return window.localStorage;
};

export const setCustomServerConfigStorageAdapter = (adapter: StorageAdapter | null) => {
  storageAdapter = adapter;
};

const isDevelopmentBuild = () => process.env['NODE_ENV'] === 'development';

const normalizeHostname = (hostname: string) => hostname.toLowerCase().replace(/^\[|\]$/g, '');

const isPrivateIpv4 = (hostname: string) => {
  const parts = hostname.split('.');
  if (parts.length !== 4) return false;
  const octets = parts.map((part) => Number(part));
  if (octets.some((octet) => !Number.isInteger(octet) || octet < 0 || octet > 255)) return false;

  const first = octets[0]!;
  const second = octets[1]!;
  return (
    first === 10 ||
    first === 127 ||
    first === 0 ||
    (first === 172 && second >= 16 && second <= 31) ||
    (first === 192 && second === 168) ||
    (first === 169 && second === 254)
  );
};

const isLocalOrPrivateHost = (hostname: string) => {
  const normalized = normalizeHostname(hostname);
  return (
    normalized === 'localhost' ||
    normalized === '::1' ||
    normalized.endsWith('.local') ||
    isPrivateIpv4(normalized)
  );
};

export const normalizeServerBaseUrl = (
  input: string,
  { allowInsecureHttp = isDevelopmentBuild() }: NormalizeUrlOptions = {},
) => {
  const trimmed = input.trim();
  if (!trimmed) {
    throw new CustomServerConfigError('invalid-url', 'Server URL is required.');
  }

  let parsed: URL;
  try {
    parsed = new URL(trimmed);
  } catch {
    throw new CustomServerConfigError('invalid-url', 'Server URL must be a valid URL.');
  }

  if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
    throw new CustomServerConfigError('invalid-url', 'Server URL must use http or https.');
  }

  if (parsed.username || parsed.password) {
    throw new CustomServerConfigError('invalid-url', 'Server URL must not include credentials.');
  }

  if (
    parsed.protocol === 'http:' &&
    !(allowInsecureHttp && isLocalOrPrivateHost(parsed.hostname))
  ) {
    throw new CustomServerConfigError(
      'insecure-http',
      'Insecure http is only allowed for local development servers.',
    );
  }

  parsed.hash = '';
  parsed.search = '';

  return parsed.toString().replace(/\/+$/, '');
};

const normalizeConfigUrl = (input: string, options: NormalizeUrlOptions) =>
  normalizeServerBaseUrl(input, options);

const joinUrlPath = (baseUrl: string, path: string) => {
  const base = baseUrl.replace(/\/+$/, '');
  return `${base}${path}`;
};

const isPlainObject = (value: unknown): value is Record<string, unknown> =>
  typeof value === 'object' && value !== null && !Array.isArray(value);

const normalizeSecretField = (field: string) => field.toLowerCase().replace(/[-\s]/g, '_');

const findDangerousSecretField = (value: unknown): string | null => {
  if (Array.isArray(value)) {
    for (const item of value) {
      const found = findDangerousSecretField(item);
      if (found) return found;
    }
    return null;
  }

  if (!isPlainObject(value)) return null;

  for (const [key, child] of Object.entries(value)) {
    const normalizedKey = normalizeSecretField(key);
    const dangerousField = DANGEROUS_SECRET_FIELDS.find((field) => normalizedKey.includes(field));
    if (dangerousField) return key;

    const found = findDangerousSecretField(child);
    if (found) return found;
  }

  return null;
};

const assertNoDangerousSecrets = (config: unknown) => {
  const field = findDangerousSecretField(config);
  if (field) {
    throw new CustomServerConfigError(
      'dangerous-secret',
      `Server config exposes a dangerous secret field: ${field}.`,
    );
  }
};

const validatePublicConfig = (
  serverBaseUrl: string,
  config: unknown,
  {
    allowInsecureHttp = isDevelopmentBuild(),
    requireSupabase = true,
  }: NormalizeUrlOptions & { requireSupabase?: boolean } = {},
): PublicReadestClientConfig => {
  assertNoDangerousSecrets(config);

  if (!isPlainObject(config)) {
    throw new CustomServerConfigError('invalid-config', 'Server config must be a JSON object.');
  }

  const apiBaseUrlValue = config['apiBaseUrl'];
  const supabaseUrlValue = config['supabaseUrl'];
  const supabaseAnonKeyValue = config['supabaseAnonKey'];

  const apiBaseUrl =
    typeof apiBaseUrlValue === 'string' && apiBaseUrlValue.trim()
      ? normalizeConfigUrl(apiBaseUrlValue, { allowInsecureHttp })
      : serverBaseUrl;

  const supabaseUrl =
    typeof supabaseUrlValue === 'string' && supabaseUrlValue.trim()
      ? normalizeConfigUrl(supabaseUrlValue, { allowInsecureHttp })
      : undefined;
  const supabaseAnonKey =
    typeof supabaseAnonKeyValue === 'string' && supabaseAnonKeyValue.trim()
      ? supabaseAnonKeyValue.trim()
      : undefined;

  if (requireSupabase && (!supabaseUrl || !supabaseAnonKey)) {
    throw new CustomServerConfigError(
      'missing-supabase-config',
      'Server config must include supabaseUrl and supabaseAnonKey.',
    );
  }

  return {
    apiBaseUrl,
    supabaseUrl,
    supabaseAnonKey,
  };
};

const fetchJsonConfig = async (url: string, fetchImpl: typeof fetch) => {
  const response = await fetchImpl(url, {
    method: 'GET',
    headers: {
      Accept: 'application/json',
    },
  });
  if (!response.ok) {
    throw new CustomServerConfigError(
      'server-not-reachable',
      `Server config endpoint returned HTTP ${response.status}.`,
    );
  }
  return response.json() as Promise<unknown>;
};

export const fetchPublicClientConfig = async (
  serverBaseUrlInput: string,
  options: ResolveCustomServerConfigOptions = {},
) => {
  const serverBaseUrl = normalizeServerBaseUrl(serverBaseUrlInput, options);
  const fetchImpl = options.fetchImpl ?? globalThis.fetch;
  if (!fetchImpl) {
    throw new CustomServerConfigError('server-not-reachable', 'Fetch API is not available.');
  }

  let lastError: unknown;
  for (const path of PUBLIC_CONFIG_PATHS) {
    try {
      const config = await fetchJsonConfig(joinUrlPath(serverBaseUrl, path), fetchImpl);
      return validatePublicConfig(serverBaseUrl, config, options);
    } catch (error) {
      if (
        error instanceof CustomServerConfigError &&
        (error.code === 'dangerous-secret' ||
          error.code === 'missing-supabase-config' ||
          error.code === 'invalid-url' ||
          error.code === 'insecure-http')
      ) {
        throw error;
      }
      lastError = error;
    }
  }

  if (lastError instanceof CustomServerConfigError) {
    throw lastError;
  }
  throw new CustomServerConfigError(
    'server-not-reachable',
    'Server config endpoints are not reachable.',
  );
};

export const resolveCustomServerConfig = async (
  serverBaseUrlInput: string,
  options: ResolveCustomServerConfigOptions = {},
): Promise<CustomServerConfig> => {
  const serverBaseUrl = normalizeServerBaseUrl(serverBaseUrlInput, options);
  const publicConfig = await fetchPublicClientConfig(serverBaseUrl, options);

  return {
    serverBaseUrl,
    apiBaseUrl: publicConfig.apiBaseUrl ?? serverBaseUrl,
    supabaseUrl: publicConfig.supabaseUrl,
    supabaseAnonKey: publicConfig.supabaseAnonKey,
    fetchedAt: options.now?.() ?? Date.now(),
  };
};

export const saveCustomServerConfig = async (
  config: CustomServerConfig,
  { resetSession = false }: SaveCustomServerConfigOptions = {},
) => {
  const storage = getStorageAdapter();
  const previous = loadCustomServerConfig();
  storage?.setItem(CUSTOM_SERVER_CONFIG_KEY, JSON.stringify(config));

  if (resetSession && previous?.serverBaseUrl !== config.serverBaseUrl) {
    const { clearAuthSessionForServerChange } = await import('@/helpers/auth');
    await clearAuthSessionForServerChange();
  }
};

export const loadCustomServerConfig = (): CustomServerConfig | null => {
  const storage = getStorageAdapter();
  if (!storage) return null;

  const raw = storage.getItem(CUSTOM_SERVER_CONFIG_KEY);
  if (!raw) return null;

  try {
    const parsed = JSON.parse(raw) as unknown;
    if (!isPlainObject(parsed)) return null;
    const serverBaseUrl = parsed['serverBaseUrl'];
    const apiBaseUrl = parsed['apiBaseUrl'];
    const fetchedAt = parsed['fetchedAt'];
    if (
      typeof serverBaseUrl !== 'string' ||
      typeof apiBaseUrl !== 'string' ||
      typeof fetchedAt !== 'number'
    ) {
      return null;
    }

    return {
      serverBaseUrl,
      apiBaseUrl,
      supabaseUrl:
        typeof parsed['supabaseUrl'] === 'string' ? (parsed['supabaseUrl'] as string) : undefined,
      supabaseAnonKey:
        typeof parsed['supabaseAnonKey'] === 'string'
          ? (parsed['supabaseAnonKey'] as string)
          : undefined,
      fetchedAt,
    };
  } catch {
    return null;
  }
};

export const clearCustomServerConfig = async ({
  resetSession = false,
}: SaveCustomServerConfigOptions = {}) => {
  const previous = loadCustomServerConfig();
  const storage = getStorageAdapter();
  storage?.removeItem(CUSTOM_SERVER_CONFIG_KEY);

  if (resetSession && previous) {
    const { clearAuthSessionForServerChange } = await import('@/helpers/auth');
    await clearAuthSessionForServerChange();
  }
};

export const getCustomServerRuntimeConfig = (): PublicReadestClientConfig | null => {
  const config = loadCustomServerConfig();
  if (!config) return null;
  return {
    apiBaseUrl: config.apiBaseUrl,
    supabaseUrl: config.supabaseUrl,
    supabaseAnonKey: config.supabaseAnonKey,
  };
};

export const getCustomServerConfigStorageKey = () => CUSTOM_SERVER_CONFIG_KEY;
