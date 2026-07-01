import { NextResponse } from 'next/server';
import { getServerRuntimeConfig } from '@/services/runtimeConfig';

export const dynamic = 'force-dynamic';

export function GET() {
  const { supabaseUrl, supabaseAnonKey, apiBaseUrl } = getServerRuntimeConfig();
  return NextResponse.json({ supabaseUrl, supabaseAnonKey, apiBaseUrl });
}
