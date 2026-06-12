// Minimal Chrome DevTools Protocol client for verifiers.
// Evaluates one JS expression in the first page target and prints the
// result as JSON on stdout. No dependencies — native WebSocket (node >= 22).
//
// usage: node cdp.mjs PORT 'expression' [TARGET_MATCH]
//
// TARGET_MATCH (optional): case-insensitive substring of the page target's
// title or URL — needed for multi-page CEF hosts like Steam, where "first
// page target" is ambiguous. Without it, the first page target is used.
//
// The expression may be async (it is awaited). Exit codes:
//   0 evaluated cleanly, 2 page threw, 3 no page target / connect failure.

const [port, expr, match] = process.argv.slice(2);
if (!port || !expr) {
    console.error("usage: node cdp.mjs PORT 'expression' [TARGET_MATCH]");
    process.exit(64);
}

let targets;
try {
    targets = await (await fetch(`http://127.0.0.1:${port}/json`)).json();
} catch {
    console.error(`cdp: nothing listening on port ${port}`);
    process.exit(3);
}
const pages = targets.filter((t) => t.type === "page");
const m = match?.toLowerCase();
const page = m
    ? pages.find((t) => t.title?.toLowerCase().includes(m) || t.url?.toLowerCase().includes(m))
    : pages[0];
if (!page) {
    console.error(m ? `cdp: no page target matching '${match}'` : "cdp: no page target");
    process.exit(3);
}

const ws = new WebSocket(page.webSocketDebuggerUrl);
const reply = new Promise((resolve, reject) => {
    ws.onmessage = (m) => {
        const msg = JSON.parse(m.data);
        if (msg.id === 1) resolve(msg);
    };
    ws.onerror = reject;
    setTimeout(() => reject(new Error("cdp: timeout")), 15000);
});
await new Promise((r) => (ws.onopen = r));
ws.send(
    JSON.stringify({
        id: 1,
        method: "Runtime.evaluate",
        params: { expression: expr, returnByValue: true, awaitPromise: true },
    }),
);

const msg = await reply;
ws.close();
if (msg.result?.exceptionDetails) {
    console.error(msg.result.exceptionDetails.exception?.description ?? "cdp: page threw");
    process.exit(2);
}
console.log(JSON.stringify(msg.result?.result?.value ?? null));
