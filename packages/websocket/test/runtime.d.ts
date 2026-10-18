declare module "mygo-runtime" {
  export class Channel<T> {
    constructor(onmessage: (value: T) => void);
    close(): void;
  }
  export function call<T>(name: string, ...params: unknown[]): Promise<T>;
  export function isCallError(error: unknown): error is Error;
}
