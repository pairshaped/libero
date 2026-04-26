export function getFlags() {
  const f = globalThis.window?.__LIBERO_FLAGS__;
  if (!f) {
    throw new Error("__LIBERO_FLAGS__ is not set — was ssr.boot_script called on the server?");
  }
  return f;
}
