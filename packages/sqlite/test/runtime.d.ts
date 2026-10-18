declare module "mygo-runtime" {
  export function call<T>(name: string, ...params: unknown[]): Promise<T>;
}
