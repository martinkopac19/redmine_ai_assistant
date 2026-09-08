/* Screenshot banneru duplicit po presmerovani na formular ineho projektu.
 *
 *   node extra/dup_shot.mjs <base> <login> <heslo> <homeProjectId> <outPng> [port]
 */
const [BASE, LOGIN, PASS, HOME, OUT, PORT = '9351'] = process.argv.slice(2);
const SUBJECT = 'POS tables return HTTP 500 on load 0709';
const fs = await import('node:fs');

const list = await (await fetch('http://127.0.0.1:' + PORT + '/json')).json();
const ws = new WebSocket(list.find(t => t.type === 'page').webSocketDebuggerUrl);
let id = 0; const pending = new Map();
const send = (m, p = {}) => new Promise(res => { const i = ++id; pending.set(i, res); ws.send(JSON.stringify({ id: i, method: m, params: p })); });
ws.onmessage = e => { const m = JSON.parse(e.data); if (m.id && pending.has(m.id)) { pending.get(m.id)(m.result); pending.delete(m.id); } };
await new Promise(r => { ws.onopen = r; });

const sleep = ms => new Promise(r => setTimeout(r, ms));
const ev = async expr => (await send('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise: true }))?.result?.value;
async function waitFor(expr, label, ms = 120000) {
  const until = Date.now() + ms;
  for (;;) {
    try { if (await ev(expr)) return true; } catch (e) {}
    if (Date.now() > until) throw new Error('timeout: ' + label);
    await sleep(250);
  }
}
const J = s => JSON.stringify(s);

await send('Page.enable');
await send('Page.navigate', { url: BASE + '/login?nosso=1' });
await waitFor('document.readyState === "complete"', 'login');
if (await ev(`!!document.getElementById('username')`)) {
  await ev(`(function(){document.getElementById('username').value=${J(LOGIN)};document.getElementById('password').value=${J(PASS)};document.getElementById('login-form').querySelector('input[type=submit]').click();return 1;})()`);
  await waitFor(`!!document.querySelector('#loggedas')`, 'prihlasenie');
}

await send('Page.navigate', { url: BASE + '/projects/' + HOME + '/issues/new' });
await waitFor('document.readyState === "complete"', 'formular');
await sleep(700);
await ev(`(function(){
  var s = document.getElementById('issue_subject');
  s.value = ${J(SUBJECT)};
  s.dispatchEvent(new Event('input', { bubbles: true }));
  document.querySelector('.ai-assistant-btn[data-raa="draft"]').click();
  return 1;
})()`);
await waitFor(`String(window.location.pathname) !== '/projects/${HOME}/issues/new'`, 'presmerovanie');
await waitFor(`(function(){var p=document.getElementById('raa-draft-notes');return !!p && !p.hidden;})()`, 'banner');
await sleep(900);

/* `clip` je v suradniciach DOKUMENTU, nie viewportu — po scrollIntoView treba
 * k getBoundingClientRect() pripocitat window.scrollX/scrollY. */
const box = await ev(`(function(){
  var h = document.querySelector('#content > h2');
  var p = document.getElementById('raa-draft-notes');
  h.scrollIntoView();
  var a = h.getBoundingClientRect(), b = p.getBoundingClientRect();
  return JSON.stringify({ x: Math.min(a.left, b.left) + window.scrollX - 12,
                          y: a.top + window.scrollY - 12,
                          width: Math.max(a.width, b.width) + 24,
                          height: (b.bottom - a.top) + 24 });
})()`);
const clip = JSON.parse(box);
const shot = await send('Page.captureScreenshot', { format: 'png', clip: { ...clip, scale: 1 } });
fs.writeFileSync(OUT, Buffer.from(shot.data, 'base64'));
console.log('ulozene: ' + OUT + '  (' + JSON.stringify(clip) + ')');
console.log('url: ' + (await ev('String(window.location.pathname)')));
ws.close();
