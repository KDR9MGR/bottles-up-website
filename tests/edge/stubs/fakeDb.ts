// A tiny in-memory stand-in for the Supabase client, covering just the query
// shapes the edge functions use: select / insert / update with eq, is, in,
// then single() / maybeSingle() / await, plus rpc().
//
// Rows are stored as given. Embedded relations (`select('*, venue:site_venues(*)')`)
// are NOT resolved: seed the row with the nested object already attached.
//
// Important property: an UPDATE only touches rows matching its filters, and
// returns those rows when .select() follows. That is what makes the code's
// atomic "claim" pattern (`update ... .is('ticket_code', null)`) testable: a
// second claimer matches zero rows, exactly as in Postgres.

type Row = Record<string, any>;

export interface FakeDb {
  client: any;
  tables: Record<string, Row[]>;
  rpcCalls: { name: string; args: any }[];
  writes: { table: string; op: 'insert' | 'update'; values: any; matched: number }[];
  /** Runs just before every insert/update. Use it to simulate a competing writer. */
  beforeWrite: ((table: string, op: 'insert' | 'update') => void) | null;
  rpcHandlers: Record<string, (args: any) => any>;
}

const clone = <T>(v: T): T => (v === undefined ? v : structuredClone(v));

export function createFakeDb(seed: Record<string, Row[]> = {}): FakeDb {
  const db: FakeDb = {
    client: null,
    tables: Object.fromEntries(Object.entries(seed).map(([t, rows]) => [t, rows.map(clone)])),
    rpcCalls: [],
    writes: [],
    beforeWrite: null,
    rpcHandlers: {},
  };

  class Query {
    private op: 'select' | 'update' | 'insert' = 'select';
    private filters: ((r: Row) => boolean)[] = [];
    private payload: any;
    private wantRows = false;
    constructor(private table: string) {
      if (!db.tables[table]) db.tables[table] = [];
    }
    select(_cols?: string) {
      if (this.op !== 'select') this.wantRows = true;
      return this;
    }
    update(values: Row) { this.op = 'update'; this.payload = values; return this; }
    insert(values: Row | Row[]) { this.op = 'insert'; this.payload = values; return this; }
    eq(col: string, val: any) { this.filters.push((r) => r[col] === val); return this; }
    is(col: string, val: any) { this.filters.push((r) => (val === null ? r[col] == null : r[col] === val)); return this; }
    in(col: string, vals: any[]) { this.filters.push((r) => vals.includes(r[col])); return this; }
    order() { return this; }
    limit() { return this; }

    private exec(): { data: any; error: any } {
      const rows = db.tables[this.table];
      if (this.op === 'select') {
        return { data: rows.filter((r) => this.filters.every((f) => f(r))).map(clone), error: null };
      }
      db.beforeWrite?.(this.table, this.op);
      if (this.op === 'update') {
        const matched = rows.filter((r) => this.filters.every((f) => f(r)));
        matched.forEach((r) => Object.assign(r, clone(this.payload)));
        db.writes.push({ table: this.table, op: 'update', values: clone(this.payload), matched: matched.length });
        return { data: this.wantRows ? matched.map(clone) : null, error: null };
      }
      const toInsert = (Array.isArray(this.payload) ? this.payload : [this.payload]).map((r: Row) => ({
        id: `fake-${this.table}-${rows.length + 1}`,
        ...clone(r),
      }));
      rows.push(...toInsert);
      db.writes.push({ table: this.table, op: 'insert', values: clone(this.payload), matched: toInsert.length });
      return { data: this.wantRows ? toInsert.map(clone) : null, error: null };
    }

    single() {
      const { data, error } = this.exec();
      if (error) return Promise.resolve({ data: null, error });
      if (!Array.isArray(data) || data.length !== 1) {
        return Promise.resolve({ data: null, error: { message: `expected 1 row, got ${Array.isArray(data) ? data.length : 0}` } });
      }
      return Promise.resolve({ data: data[0], error: null });
    }
    maybeSingle() {
      const { data, error } = this.exec();
      if (error) return Promise.resolve({ data: null, error });
      if (!Array.isArray(data) || data.length === 0) return Promise.resolve({ data: null, error: null });
      if (data.length > 1) return Promise.resolve({ data: null, error: { message: 'multiple rows' } });
      return Promise.resolve({ data: data[0], error: null });
    }
    then(resolve: (v: any) => any, reject?: (e: any) => any) {
      return Promise.resolve(this.exec()).then(resolve, reject);
    }
  }

  db.client = {
    from: (table: string) => new Query(table),
    rpc: (name: string, args: any) => {
      db.rpcCalls.push({ name, args: clone(args) });
      const handler = db.rpcHandlers[name];
      return Promise.resolve({ data: handler ? handler(args) : null, error: null });
    },
  };
  return db;
}
