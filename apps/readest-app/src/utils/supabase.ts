import { createClient } from '@supabase/supabase-js';
import type { SupabaseClient } from '@supabase/supabase-js';
import { getRuntimeConfig } from '@/services/runtimeConfig';

const decodeRequiredBase64 = (value: string | undefined) => (value ? atob(value) : '');

const getSupabasePublicConfig = () => {
  const runtimeConfig = getRuntimeConfig();
  return {
    supabaseUrl:
      runtimeConfig?.supabaseUrl ||
      process.env['SUPABASE_URL'] ||
      process.env['NEXT_PUBLIC_SUPABASE_URL'] ||
      decodeRequiredBase64(process.env['NEXT_PUBLIC_DEFAULT_SUPABASE_URL_BASE64']),
    supabaseAnonKey:
      runtimeConfig?.supabaseAnonKey ||
      process.env['SUPABASE_ANON_KEY'] ||
      process.env['NEXT_PUBLIC_SUPABASE_ANON_KEY'] ||
      decodeRequiredBase64(process.env['NEXT_PUBLIC_DEFAULT_SUPABASE_KEY_BASE64']),
  };
};

let cachedPublicClient: SupabaseClient | null = null;
let cachedPublicClientKey = '';

export const getSupabaseClient = () => {
  const { supabaseUrl, supabaseAnonKey } = getSupabasePublicConfig();
  const cacheKey = `${supabaseUrl}\n${supabaseAnonKey}`;
  if (!cachedPublicClient || cachedPublicClientKey !== cacheKey) {
    cachedPublicClient = createClient(supabaseUrl, supabaseAnonKey);
    cachedPublicClientKey = cacheKey;
  }
  return cachedPublicClient;
};

export const resetSupabaseClientCache = () => {
  cachedPublicClient = null;
  cachedPublicClientKey = '';
};

export const supabase = new Proxy({} as SupabaseClient, {
  get(_target, property, receiver) {
    const value = Reflect.get(getSupabaseClient(), property, receiver);
    return typeof value === 'function' ? value.bind(getSupabaseClient()) : value;
  },
});

export const createSupabaseClient = (accessToken?: string) => {
  const { supabaseUrl, supabaseAnonKey } = getSupabasePublicConfig();
  return createClient(supabaseUrl, supabaseAnonKey, {
    global: {
      headers: accessToken
        ? {
            Authorization: `Bearer ${accessToken}`,
          }
        : {},
    },
  });
};

export const createSupabaseAdminClient = () => {
  const { supabaseUrl } = getSupabasePublicConfig();
  const supabaseAdminKey = process.env['SUPABASE_ADMIN_KEY'] || '';
  return createClient(supabaseUrl, supabaseAdminKey, {
    auth: {
      persistSession: false,
      autoRefreshToken: false,
      detectSessionInUrl: false,
    },
  });
};
