import { User } from '@supabase/supabase-js';
import { resetSupabaseClientCache, supabase } from '@/utils/supabase';

interface UseAuthCallbackOptions {
  accessToken?: string | null;
  refreshToken?: string | null;
  login: (accessToken: string, user: User) => void;
  navigate: (path: string) => void;
  type?: string | null;
  next?: string;
  error?: string | null;
  errorCode?: string | null;
  errorDescription?: string | null;
}

const APP_AUTH_STORAGE_KEYS = ['token', 'refresh_token', 'user', 'lastRedirectAt'] as const;
const SUPABASE_AUTH_STORAGE_KEY_PATTERN = /^sb-.+-auth-token$/;

export const clearStoredAuthSession = () => {
  if (typeof window === 'undefined') return;

  for (const key of APP_AUTH_STORAGE_KEYS) {
    localStorage.removeItem(key);
  }

  for (const key of Object.keys(localStorage)) {
    if (SUPABASE_AUTH_STORAGE_KEY_PATTERN.test(key)) {
      localStorage.removeItem(key);
    }
  }
};

export const clearAuthSessionForServerChange = async () => {
  try {
    await supabase.auth.signOut();
  } catch {
    // Best-effort: local auth state still must be cleared when changing servers.
  } finally {
    clearStoredAuthSession();
    resetSupabaseClientCache();
  }
};

export function handleAuthCallback({
  accessToken,
  refreshToken,
  login,
  navigate,
  type,
  next = '/',
  error,
}: UseAuthCallbackOptions) {
  async function finalizeSession() {
    if (error) {
      navigate('/auth/error');
      return;
    }

    if (!accessToken || !refreshToken) {
      navigate('/library');
      return;
    }

    const { error: err } = await supabase.auth.setSession({
      access_token: accessToken,
      refresh_token: refreshToken,
    });

    if (err) {
      console.error('Error setting session:', err);
      navigate('/auth/error');
      return;
    }

    const {
      data: { user },
    } = await supabase.auth.getUser();
    if (user) {
      login(accessToken, user);
      if (type === 'recovery') {
        navigate('/auth/recovery');
        return;
      }
      navigate(next);
    } else {
      console.error('Error fetching user data');
      navigate('/auth/error');
    }
  }

  finalizeSession();
}
