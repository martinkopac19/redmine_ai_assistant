/* Vypinac „AI navrh odpovede" (0.6.4) — v UI aj na endpointe.
 *
 * Overuje to, co selftest overit nemoze: ze checkbox je v administracii, ze sa
 * ulozi, ze vypnutim zmizne tlacidlo na ulohe a ze endpoint vrati 403.
 *
 * Stav nastavenia na konci VRACIA do puvodnej hodnoty.
 *
 *   node extra/suggest_switch_cdp_test.mjs <base> <login> <heslo> <issueId> [port]
 */
const [BASE, LOGIN, PASS, ISSUE, PORT = '9391'] = process.argv.slice(2);
if (!ISSUE) {
  console.error('pouzitie: node suggest_switch_cdp_test.mjs <base> <login> <heslo> <issueId> [port]');
  process.exit(2);
}

const list = await (await fetch('http://127.0.0.1:' + PORT + '/json')).json();
const ws = new WebSocket(list.find(t => t.type === 'page').webSocketDebuggerUrl);
let id = 0; const pending = new Map();
const send = (m, p = {}) => new Promise(r => { const i = ++id; pending.set(i, r); ws.send(JSON.stringify({ id: i, method: m, params: p })); });
ws.onmessage = e => { const m = JSON.parse(e.data); if (m.id && pending.has(m.id)) { pending.get(m.id)(m.result); pending.delete(m.id); } };
await new Promise(r => { ws.onopen = r; });

const sleep = ms => new Promise(r => setTimeout(r, ms));
const ev = async x => {
  const r = await send('Runtime.evaluate', { expression: x, returnByValue: true, awaitPromise: true });
  if (r?.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description || 'JS err');
  return r?.result?.value;
};
async function waitFor(x, label, ms = 25000) {
  const until = Date.now() + ms;
  for (;;) { try { if (await ev(x)) return true; } catch (e) {} if (Date.now() > until) throw new Error('timeout: ' + label); await sleep(250); }
}
async function nav(url) {
  await send('Page.navigate', { url });
  await waitFor('document.readyState === "complete"', 'nacitanie ' + url);
  await sleep(900);
}

const OK = []; const BAD = [];
function check(label, got, want) {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  (ok ? OK : BAD).push(label);
  console.log('  ' + label.padEnd(56) + (ok ? 'OK' : '!! ZLE (' + JSON.stringify(got) + ', cakalo sa ' + JSON.stringify(want) + ')'));
}
const J = s => JSON.stringify(s);

const SETTINGS = BASE + '/settings/plugin/redmine_ai_assistant';
const CB = `document.querySelector('input[type=checkbox][name="settings[suggest_enabled]"]')`;
const BTN = `document.querySelector('.ai-assistant-btn[data-raa="suggest"]')`;

/* Prepne checkbox na danu hodnotu a ulozi formular nastaveni. */
async function setSwitch(on) {
  await nav(SETTINGS);
  await ev(`(function(){
    var cb = ${CB};
    if (!cb) return 'checkbox nenajdeny';
    cb.checked = ${on ? 'true' : 'false'};
    cb.closest('form').submit();
    return 'ok';
  })()`);
  await waitFor('document.readyState === "complete"', 'ulozenie nastaveni', 30000);
  await sleep(1200);
}

/* Zavola endpoint priamo, aby sa overilo, ze vypinac plati aj na serveri
 * a nie len na tlacidle. CSRF token sa berie z hlavicky stranky. */
async function callEndpoint() {
  return ev(`(async function(){
    var t = (document.querySelector('meta[name="csrf-token"]')||{}).content || '';
    var r = await fetch('/ai_assistant/suggest', {
      method: 'POST', credentials: 'same-origin',
      headers: {'Content-Type':'application/json','Accept':'application/json','X-CSRF-Token': t},
      body: JSON.stringify({issue_id: ${J(String(ISSUE))}})
    });
    return r.status;
  })()`);
}

console.log('='.repeat(80));
console.log('  ai_assistant — vypinac „AI navrh odpovede"');
console.log('='.repeat(80));

await send('Page.enable');
await nav(BASE + '/login?nosso=1');
if (await ev(`!!document.getElementById('username')`)) {
  await ev(`(function(){document.getElementById('username').value=${J(LOGIN)};document.getElementById('password').value=${J(PASS)};document.getElementById('login-form').querySelector('input[type=submit]').click();return 1;})()`);
  await waitFor(`!!document.querySelector('#loggedas')`, 'prihlasenie');
}

console.log('\n[1] Nastavenie je v administracii');
await nav(SETTINGS);
check('checkbox existuje', await ev(`!!${CB}`), true);
check('ma popisok o navrhu odpovede',
  await ev(`(function(){
    var cb = ${CB}, p = cb && cb.closest('p');
    return !!p && /(n\\u00e1vrh odpoved|reply suggestion|n\\u00e1vrh odpov\\u011bd)/i.test(p.textContent);
  })()`), true);
check('je v sekcii navrhu odpovede (nie u draftu ani planu)',
  await ev(`(function(){
    var cb = ${CB}, fs = cb && cb.closest('fieldset');
    return !!fs && !/GitLab/i.test((fs.querySelector('legend')||{}).textContent||'');
  })()`), true);
const orig = await ev(`${CB}.checked`);
console.log('  pociatocna hodnota: ' + orig);
/* Default je ZAPNUTE, takze odskrtnuty checkbox pri prvom nacitani znamena
 * jedno z dvoch: admin funkciu vedome vypol, ALEBO partial cita `settings[...]`
 * namiesto efektivnej hodnoty a ukazuje vypnute, hoci funkcia bezi.
 * To druhe je chyba, kvoli ktorej tento test 10. 9. 2026 funkciu na serveri
 * naozaj vypol (ulozil na konci „povodnu\" hodnotu false). Preto sa to hlasi. */
check('checkbox odraza EFEKTIVNU hodnotu (default je zapnute)', orig, true);
if (orig !== true) {
  console.log('  !! POZOR: checkbox je odskrtnuty. Ak si funkciu nevypol vedome,');
  console.log('  !! partial cita ulozeny hash namiesto RedmineAiAssistant.setting().');
}

console.log('\n[2] ZAPNUTE: tlacidlo je na ulohe a endpoint pusti');
await setSwitch(true);
await nav(BASE + '/issues/' + ISSUE);
check('tlacidlo „AI navrh odpovede" je na stranke', await ev(`!!${BTN}`), true);
const st1 = await callEndpoint();
console.log('  endpoint vratil: ' + st1);
check('endpoint NEVRACIA 403', st1 !== 403, true);

console.log('\n[3] VYPNUTE: tlacidlo zmizne a endpoint vrati 403');
await setSwitch(false);
await nav(BASE + '/issues/' + ISSUE);
check('tlacidlo na stranke NIE JE', await ev(`!!${BTN}`), false);
const st2 = await callEndpoint();
console.log('  endpoint vratil: ' + st2);
check('endpoint vracia 403', st2, 403);

console.log('\n[4] Vypnutie sa nedotklo ostatnych funkcii');
check('prutik AI (rezim planu) je stale v hlavicke',
  await ev(`!!document.querySelector('a[data-raa="plan"]')`), true);
check('AI Summarizer je stale na ulohe',
  await ev(`!!document.querySelector('[data-raa="summary"]')`), true);

console.log('\n[5] Znovu ZAPNUTE: tlacidlo sa vrati');
await setSwitch(true);
await nav(BASE + '/issues/' + ISSUE);
check('tlacidlo je zas na stranke', await ev(`!!${BTN}`), true);

/* Test konci so ZAPNUTYM vypinacom — zamerne.
 *
 * Pokus „vratit povodnu hodnotu\" tu uz raz skodil: partial ukazoval odskrtnute
 * kvoli chybe, test to precital ako povodny stav a na konci funkciu na serveri
 * vypol. Default je zapnute, takze skoncit zapnuty je bezpecny stav; keby ju
 * niekto vedome vypol, vypne si ju znova jednym klikom. */
console.log('\n  (vypinac zostava ZAPNUTY — bezpecny stav, viac k tomu v komentari testu)');

console.log('\n' + '='.repeat(80));
console.log('  ' + OK.length + ' OK, ' + BAD.length + ' chyb');
if (BAD.length) BAD.forEach(b => console.log('  !! ' + b));
console.log('='.repeat(80));
ws.close();
process.exit(BAD.length ? 1 : 0);
