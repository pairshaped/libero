export function getPathname() {
  return globalThis.location?.pathname ?? "/inc";
}

export function pushUrl(path) {
  globalThis.history?.pushState(null, "", path);
}

export function listenNavClicks(callback) {
  document.addEventListener("click", (e) => {
    const link = e.target.closest("[data-navlink]");
    if (link) {
      e.preventDefault();
      const path = new URL(link.href).pathname;
      globalThis.history?.pushState(null, "", path);
      callback(path);
    }
  });
}

export function onPopstate(callback) {
  globalThis.addEventListener("popstate", () => {
    callback(globalThis.location?.pathname ?? "/inc");
  });
}
