// Serves /go/<slug> short links from go.json and /download, which starts the newest DMG. Each known link click
// writes one data point: the slug, the referring site's host name and the country. Everything else is a static asset.
import links from "./go.json";

// stamp-site-version.sh writes the released version here before each deploy.
const version = "0.6.0";
const dmg = `https://github.com/Dewline-ArkWerx-LLC/dewline/releases/download/v${version}/Dewline-${version}.dmg`;

export default {
  fetch(request, env) {
    const url = new URL(request.url);
    const path = url.pathname.replace(/\/+$/, "");
    if (path !== "/download" && !path.startsWith("/go/")) return new Response(null, { status: 404 });
    const slug = path === "/download" ? "download" : path.slice("/go/".length);
    let to;
    if (slug === "download") {
      to = dmg;
    } else if (Object.hasOwn(links, slug)) {
      to = new URL(links[slug], url);
    } else {
      return redirect(new URL("/", url));
    }
    let referrer = "";
    try {
      referrer = new URL(request.headers.get("Referer")).hostname;
    } catch {}
    env.GO.writeDataPoint({ indexes: [slug], blobs: [slug, referrer, request.cf?.country ?? ""], doubles: [1] });
    return redirect(to);
  },
};

function redirect(to) {
  return new Response(null, { status: 302, headers: { Location: String(to), "Cache-Control": "no-store" } });
}
