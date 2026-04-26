export function getFlags() {
  return globalThis.window?.__LIBERO_FLAGS__ ?? null;
}
