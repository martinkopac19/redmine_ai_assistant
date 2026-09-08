/* Test upozornenia na duplicity cez CDP proti ZIVEMU Redmine.
 *
 * Overuje to, co sa v okne ani v selfteste overit neda: ze banner „Mozne
 * duplicity" je na stranke aj vtedy, ked AI navrhne INY projekt a plugin preto
 * presmeruje na formular toho projektu. Prave tam banner do v0.6.3 mizol —
 * `applyDraft` volalo `window.location.assign` a `renderDraftNotes` sa uz
 * nedostalo na rad.
 *
 * Priprava:
 *   1) MODE=setup bin/rails runner -e production - < extra/dup_fixture.rb
 *   2) msedge --headless=new --disable-gpu --remote-debugging-port=<port> \
 *        --user-data-dir=<profil> about:blank &
 *   3) node extra/dup_cdp_test.mjs <base> <login> <heslo> <homeProjectId> <aiProjectId> <dupIssueId> [port]
 *
 * Puskaju sa REALNE volania Gemini (dve), takze test bere z hodinoveho limitu.
 */
const [BASE, LOGIN, PASS, HOME, AI_PROJECT, DUP, PORT = '9351'] = process.argv.slice(2);
if (!DUP) {
  console.error('pouzitie: node dup_cdp_test.mjs <base> <login> <heslo> <homeProjectId> <aiProjectId> <dupIssueId> [port]');
  process.exit(2);
}

const SUBJECT = 'POS tables return HTTP 500 on load 0709';

const list = await (await fetch('http://127.0.0.1:' + PORT + '/json')).json();
const page = list.find(t => t.type === 'page');
const ws = new WebSocket(page.webSocketDebuggerUrl);
let id = 0; const pending = new Map();
const send = (m, p = {}) => new Promise(res => { const i = ++id; pending.set(i, res); ws.send(JSON.stringify({ id: i, method: m, params: p })); });
ws.onmessage = e => {
  const m = JSON.parse(e.data);
  if (m.id && pending.has(m.id)) { pending.get(m.id)(m.result); pending.delete(m.id); return; }
  /* „Leave site?" pri odchode z rozpisaneho formulara. Programovy klik user
   * gesture nema, takze by sa nemal objavit — ale keby predsa, headless ho nikto
   * nepotvrdi a KAZDE dalsie Runtime.evaluate zamrzne bez chyby. */
  if (m.method === 'Page.javascriptDialogOpening') {
    console.log('  (dialog prehliadaca: ' + m.params.type + ' — potvrdzujem)');
    ws.send(JSON.stringify({ id: ++id, method: 'Page.handleJavaScriptDialog', params: { accept: true } }));
  }
};
await new Promise(r => { ws.onopen = r; });

const sleep = ms => new Promise(r => setTimeout(r, ms));
const ev = async expr => {
  const r = await send('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise: true });
  if (r?.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description || 'JS error');
  return r?.result?.value;
};
async function waitFor(expr, label, ms = 20000) {
  const until = Date.now() + ms;
  for (;;) {
    try { if (await ev(expr)) return true; } catch (e) { /* stranka sa prave meni */ }
    if (Date.now() > until) throw new Error('timeout: ' + label);
    await sleep(250);
  }
}
async function nav(url) {
  await send('Page.navigate', { url });
  await waitFor('document.readyState === "complete"', 'nacitanie ' + url);
  await sleep(600);
}

const OK = []; const BAD = [];
function check(label, got, want) {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  (ok ? OK : BAD).push(label);
  console.log('  ' + label.padEnd(54) + (ok ? 'OK' : '!! ZLE (' + JSON.stringify(got) + ', cakalo sa ' + JSON.stringify(want) + ')'));
}
const J = s => JSON.stringify(s);

/* Vyplni nazov a klikne na „Vytvorit s AI". Tlacidlo je disabled, kym nazov nie
 * je vyplneny, a povoluje ho `input` listener — preto sa event dispatchuje. */
const REQUEST_DRAFT = `(function(){
  var s = document.getElementById('issue_subject');
  s.value = ${J(SUBJECT)};
  s.dispatchEvent(new Event('input', { bubbles: true }));
  var b = document.querySelector('.ai-assistant-btn[data-raa="draft"]');
  if (!b) { return 'chyba: tlacidlo nie je na stranke'; }
  if (b.disabled) { return 'chyba: tlacidlo je disabled'; }
  b.click();
  return 'ok';
})()`;

const BANNER = `(function(){
  var p = document.getElementById('raa-draft-notes');
  if (!p || p.hidden) { return null; }
  return { text: p.textContent.replace(/\\s+/g, ' ').trim(),
           links: Array.prototype.map.call(p.querySelectorAll('a'), function(a){ return a.getAttribute('href'); }),
           tags: Array.prototype.map.call(p.querySelectorAll('.raa-dup-project'), function(t){ return t.textContent.trim(); }) };
})()`;

console.log('='.repeat(78));
console.log('  ai_assistant — banner duplicit (' + LOGIN + '), zadanie: ' + SUBJECT);
console.log('='.repeat(78));

await send('Page.enable');
await nav(BASE + '/login?nosso=1');
if (await ev(`!!document.getElementById('username')`)) {
  await ev(`(function(){document.getElementById('username').value=${J(LOGIN)};document.getElementById('password').value=${J(PASS)};document.getElementById('login-form').querySelector('input[type=submit]').click();return 1;})()`);
  await waitFor(`!!document.querySelector('#loggedas')`, 'prihlasenie');
}

console.log('\n[1] Preklad tlacidla (uzivatel ma jazyk sk)');
await nav(BASE + '/projects/' + HOME + '/issues/new');
check('tlacidlo je na formulari',
  await ev(`!!document.querySelector('.ai-assistant-btn[data-raa="draft"]')`), true);
check('nazov tlacidla je prelozeny',
  await ev(`document.querySelector('.ai-assistant-btn[data-raa="draft"]').textContent.trim()`),
  'Vytvoriť s AI');
check('banner na cistom formulari nie je', await ev(BANNER), null);
check('sessionStorage je na zaciatku prazdny',
  await ev(`sessionStorage.getItem('raa.draft.notes')`), null);

console.log('\n[2] AI navrhne INY projekt → presmerovanie (jadro opravy)');
check('start je v projekte ' + HOME,
  await ev(`String(window.location.pathname)`), '/projects/' + HOME + '/issues/new');
check('poziadavka odosla', await ev(REQUEST_DRAFT), 'ok');
// Gemini: dve volania (preklad klucovych slov + navrh), pokojne 60 s.
await waitFor(`String(window.location.pathname) !== '/projects/${HOME}/issues/new'`,
  'presmerovanie na formular navrhnuteho projektu', 120000);
await waitFor('document.readyState === "complete"', 'nacitanie noveho formulara', 30000);
await sleep(900);
check('presmerovalo na projekt navrhnuty AI',
  await ev(`String(window.location.pathname)`), '/projects/' + AI_PROJECT + '/issues/new');
/* Nazov sa NEporovnava na rovnost so zadanim: model navrhuje aj nazov ulohy
 * a bezne ho preformuluje (z tohto zadania zhodil koncove „0709"). */
check('nazov od AI je vo formulari',
  await ev(`/POS tables/i.test(document.getElementById('issue_subject').value)`), true);
check('popis formular ma vyplneny',
  await ev(`document.getElementById('issue_description').value.length > 20`), true);

const banner = await ev(BANNER);
console.log('  banner: ' + JSON.stringify(banner));
check('BANNER JE NA STRANKE aj po presmerovani', banner !== null, true);
check('banner odkazuje na duplicitu #' + DUP,
  (banner?.links || []).some(h => String(h).endsWith('/issues/' + DUP)), true);
check('duplicita je oznacena nazvom cudzieho projektu',
  (banner?.tags || []).length > 0, true);

console.log('\n[3] Banner je jednorazovy');
check('sessionStorage je po vykresleni prazdny',
  await ev(`sessionStorage.getItem('raa.draft.notes')`), null);
await nav(BASE + '/projects/' + AI_PROJECT + '/issues/new');
check('po refreshi sa banner neobjavi znova', await ev(BANNER), null);

console.log('\n[4] Bez prepnutia projektu — banner ako doteraz (regresia)');
await nav(BASE + '/projects/' + AI_PROJECT + '/issues/new');
check('poziadavka odosla', await ev(REQUEST_DRAFT), 'ok');
await waitFor(`(function(){var p=document.getElementById('raa-draft-notes');return !!p && !p.hidden;})()`,
  'banner na tej istej stranke', 120000);
const banner2 = await ev(BANNER);
console.log('  banner: ' + JSON.stringify(banner2));
check('zostalo na tom istom formulari',
  await ev(`String(window.location.pathname)`), '/projects/' + AI_PROJECT + '/issues/new');
check('banner odkazuje na duplicitu #' + DUP,
  (banner2?.links || []).some(h => String(h).endsWith('/issues/' + DUP)), true);
check('sessionStorage sa pri tejto ceste nepouzil',
  await ev(`sessionStorage.getItem('raa.draft.notes')`), null);

console.log('\n[5] Sanitacia podvrhnuteho obsahu z sessionStorage');
await ev(`(function(){
  sessionStorage.setItem('raa.draft.notes', JSON.stringify({
    v: 1, created: Date.now(), projectId: ${J(String(AI_PROJECT))},
    similar: [
      { id: 'nie cislo', subject: 'zahodit' },
      { id: '<img src=x onerror=alert(1)>', subject: 'zahodit tiez' },
      { id: ${J(String(DUP))}, subject: '<b>tag ako text</b>', reason: 'r', project: 'P', other_project: 'ano' }
    ]
  }));
  return 1;
})()`);
await nav(BASE + '/projects/' + AI_PROJECT + '/issues/new');
const banner3 = await ev(BANNER);
console.log('  banner: ' + JSON.stringify(banner3));
check('polozky s necislenym id sa zahodili',
  (banner3?.links || []).length, 1);
check('HTML z ulozista sa vlozilo ako TEXT, nie ako markup',
  await ev(`(function(){var p=document.getElementById('raa-draft-notes');return !!p && p.querySelectorAll('b, img').length === 0;})()`), true);
check('other_project ako string neplati za true (ziadny nazov projektu)',
  (banner3?.tags || []).length, 0);

console.log('\n[6] Prosle duplicity sa nevykreslia');
await ev(`(function(){
  sessionStorage.setItem('raa.draft.notes', JSON.stringify({
    v: 1, created: Date.now() - 6 * 60 * 1000, projectId: ${J(String(AI_PROJECT))},
    similar: [{ id: ${J(String(DUP))}, subject: 'stare' }]
  }));
  return 1;
})()`);
await nav(BASE + '/projects/' + AI_PROJECT + '/issues/new');
check('banner starsi nez TTL sa zahodil', await ev(BANNER), null);
check('a z ulozista sa aj tak zmazal',
  await ev(`sessionStorage.getItem('raa.draft.notes')`), null);

console.log('\n[7] Duplicity z iného projektu sa nevykreslia');
await ev(`(function(){
  sessionStorage.setItem('raa.draft.notes', JSON.stringify({
    v: 1, created: Date.now(), projectId: ${J(String(HOME))},
    similar: [{ id: ${J(String(DUP))}, subject: 'patri inam' }]
  }));
  return 1;
})()`);
await nav(BASE + '/projects/' + AI_PROJECT + '/issues/new');
check('banner pre iny projekt sa nevykreslil', await ev(BANNER), null);

await ev(`sessionStorage.removeItem('raa.draft.notes')`);

console.log('\n' + '='.repeat(78));
console.log('  ' + OK.length + ' OK, ' + BAD.length + ' chyb');
if (BAD.length) { BAD.forEach(b => console.log('  !! ' + b)); }
console.log('='.repeat(78));
ws.close();
process.exit(BAD.length ? 1 : 0);
