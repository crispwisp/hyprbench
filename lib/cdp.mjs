// Minimal Chrome DevTools Protocol client for verifiers.
// Evaluates one JS expression in the first page target and prints the
// result as JSON on stdout. No dependencies — native WebSocket (node >= 22).
//
// usage: node cdp.mjs PORT 'expression'
//
// The expression may be async (it is awaited). Exit codes:
//   0 evaluated cleanly, 2 page threw, 3 no page target / connect failure.

const [port, expr] = process.argv.slice(2);
if (!port || !expr) {
    console.error("usage: node cdp.mjs PORT 'expression'");
    process.exit(64);
}

let targets;
try {
    targets = await (await fetch(`http://127.0.0.1:${port}/json`)).json();
} catch {
    console.error(`cdp: nothing listening on port ${port}`);
    process.exit(3);
}
const page = targets.find((t) => t.type === "page");
if (!page) {
    console.error("cdp: no page target");
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
