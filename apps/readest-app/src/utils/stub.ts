// Stub for excluding optional native deps from web builds (tauri-plugin-turso)
// and desktop builds (@tursodatabase/database-wasm). This module should never
// be invoked at runtime — Database.load throws if it ever is.

export interface QueryResult {
  rowsAffected: number;
  lastInsertId?: number;
}

export class Database {
  static async load(_path: string): Promise<Database> {
    throw new Error('Database stub: native DB unavailable in this build target');
  }
  async execute(_sql: string, _params?: unknown[]): Promise<QueryResult> {
    throw new Error('Database stub: native DB unavailable in this build target');
  }
  async select<T = unknown>(_sql: string, _params?: unknown[]): Promise<T[]> {
    throw new Error('Database stub: native DB unavailable in this build target');
  }
  async close(): Promise<void> {
    return;
  }
}

export default Database;
