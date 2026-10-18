declare module "mygo-runtime" {
  export class Channel<T> implements AsyncIterable<T> {
    close(): void;
    [Symbol.asyncIterator](): AsyncIterator<T>;
  }

  export function call<T>(method: string, ...args: unknown[]): Promise<T>;
  export function isCallError(error: unknown): error is Error;
}
