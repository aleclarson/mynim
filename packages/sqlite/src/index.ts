import { call } from "mygo-runtime";

/** SQLite values. Large integers stay bigint instead of losing precision. */
export type Value = null | number | bigint | string | Uint8Array;
/** Booleans bind as SQLite integers 0 and 1. */
export type Parameter = Value | boolean;
export interface OpenOptions { readOnly?: boolean }
export interface Result {
  changes: number;
  /** Last inserted row id, without precision loss. */
  lastInsertId: bigint;
}
/** Ordered columns and cells preserve duplicate column names. */
export interface Rows { columns: string[]; rows: Value[][] }
export interface Statement {
  sql: string;
  params?: readonly Parameter[];
}

interface WireValue {
  type: string;
  integer?: string;
  real?: number;
  special?: "Infinity" | "-Infinity" | "NaN";
  text?: string;
  blob?: string;
}
interface WireResult { changes: number; lastInsertId: string }
interface WireRows { columns: string[]; rows: WireValue[][] }

/** Opens a file name in the app's SQLite data directory, or a private memory DB. */
export async function open(
  name: string,
  options: OpenOptions = {},
): Promise<Database> {
  return Database.open(name, options);
}

/** A page-owned connection. The native plugin closes it when its page ends. */
export class Database {
  private closing?: Promise<void>;
  private closed = false;

  private constructor(private readonly id: string) {}

  static async open(name: string, options: OpenOptions = {}): Promise<Database> {
    const id = await call<string>("plugin:sqlite.Open", name, {
      readOnly: options.readOnly ?? false,
    });
    return new Database(id);
  }

  /** Executes exactly one statement. Bind values instead of interpolating SQL. */
  async execute(
    sql: string,
    params: readonly Parameter[] = [],
  ): Promise<Result> {
    this.assertOpen();
    const value = await call<WireResult>(
      "plugin:sqlite.Execute", this.id, sql, params.map(encode),
    );
    return result(value);
  }

  /** Queries one statement, including RETURNING. Bound large results with LIMIT. */
  async query(
    sql: string,
    params: readonly Parameter[] = [],
  ): Promise<Rows> {
    this.assertOpen();
    const value = await call<WireRows>(
      "plugin:sqlite.Query", this.id, sql, params.map(encode),
    );
    return { columns: value.columns, rows: value.rows.map((row) => row.map(decode)) };
  }

  /** Runs an atomic BEGIN IMMEDIATE batch; a failure rolls back every statement. */
  async transaction(statements: readonly Statement[]): Promise<Result[]> {
    this.assertOpen();
    const batch = statements.map((statement) => ({
      sql: statement.sql,
      args: (statement.params ?? []).map(encode),
    }));
    const values = await call<WireResult[]>(
      "plugin:sqlite.Transaction", this.id, batch,
    );
    return values.map(result);
  }

  /** Closes the connection. Concurrent and repeated closes share one call. */
  close(): Promise<void> {
    if (this.closed) return Promise.resolve();
    if (!this.closing) {
      this.closing = call<void>("plugin:sqlite.Close", this.id).then(
        () => { this.closed = true; },
        (error: unknown) => {
          this.closing = undefined;
          throw error;
        },
      );
    }
    return this.closing;
  }

  private assertOpen(): void {
    if (this.closed || this.closing) throw new Error("sqlite: database is closed");
  }
}

function result(value: WireResult): Result {
  return { changes: value.changes, lastInsertId: BigInt(value.lastInsertId) };
}

function encode(value: Parameter): WireValue {
  if (value === null) return { type: "null" };
  if (typeof value === "boolean") {
    return { type: "integer", integer: value ? "1" : "0" };
  }
  if (typeof value === "bigint") {
    if (value < -(1n << 63n) || value >= (1n << 63n)) {
      throw new RangeError("sqlite: integer exceeds signed 64-bit range");
    }
    return { type: "integer", integer: String(value) };
  }
  if (typeof value === "number") {
    if (!Number.isFinite(value)) throw new TypeError("sqlite: number must be finite");
    if (Number.isInteger(value)) {
      if (!Number.isSafeInteger(value)) {
        throw new RangeError("sqlite: use bigint for integers outside Number's safe range");
      }
      return { type: "integer", integer: String(value) };
    }
    return { type: "real", real: value };
  }
  if (typeof value === "string") return { type: "text", text: value };
  if (value instanceof Uint8Array) return { type: "blob", blob: toBase64(value) };
  throw new TypeError("sqlite: unsupported parameter");
}

function decode(value: WireValue): Value {
  switch (value.type) {
    case "null": return null;
    case "integer": {
      const integer = BigInt(value.integer!);
      return integer >= BigInt(Number.MIN_SAFE_INTEGER) &&
          integer <= BigInt(Number.MAX_SAFE_INTEGER)
        ? Number(integer)
        : integer;
    }
    case "real": return Number(value.special ?? value.real ?? 0);
    case "text": return value.text ?? "";
    case "blob": return fromBase64(value.blob ?? "");
    default: throw new TypeError(`sqlite: unknown value type ${value.type}`);
  }
}

function toBase64(bytes: Uint8Array): string {
  const native = (bytes as Uint8Array & { toBase64?: () => string }).toBase64;
  if (native) return native.call(bytes);
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000) {
    binary += String.fromCharCode.apply(
      null,
      bytes.subarray(i, i + 0x8000) as unknown as number[],
    );
  }
  return btoa(binary);
}

function fromBase64(value: string): Uint8Array {
  const native = (Uint8Array as typeof Uint8Array & {
    fromBase64?: (value: string) => Uint8Array;
  }).fromBase64;
  if (native) return native(value);
  const binary = atob(value);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}
