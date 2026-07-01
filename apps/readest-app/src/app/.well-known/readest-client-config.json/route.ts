import { NextResponse } from 'next/server';
import { getServerRuntimeConfig } from '@/services/runtimeConfig';

export const dynamic = 'force-dynamic';

export function GET() {
  return NextResponse.json(getServerRuntimeConfig());
}
