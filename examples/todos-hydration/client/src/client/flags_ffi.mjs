export function read_flags() {
  const encoded = window.__LIBERO_FLAGS__;
  if (!encoded) return "";
  return encoded;
}
