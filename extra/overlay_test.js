// Test klientskej časti: spustí SKUTOČNÝ ai_assistant.js v jsdom, klikne na
// tlačidlo AI Summarizer a skontroluje výsledný DOM. `fetch` je stubnutý, takže
// nič nikam nechodí a nestojí to žiadne volanie do Gemini.
//
// Spustenie (jsdom nie je závislosť pluginu — berieme ho z monorepa theprevio):
//   NODE_PATH=C:/Users/marti/theprevio/node_modules node extra/overlay_test.js
//
// Overuje to, čo sa v Ruby self-teste overiť nedá: presun tlačidla do lišty akcií
// aj jeho poradie, vykreslenie Markdownu na DOM nody, že HTML z modelu zostane
// textom (XSS), a všetky tri spôsoby zatvorenia okna.
const fs = require('fs');
const path = require('path');
const { JSDOM } = require('jsdom');

const PLUGIN_JS = path.join(__dirname, '..', 'assets', 'javascripts', 'ai_assistant.js');

// Presne to, čo vrátilo Gemini v end-to-end teste, + XSS pokus na overenie escapovania.
const SAMPLE = [
  '**O co jde**',
  'Jde o optimalizaci navigace pomocí klávesnice (Tab a Shift+Tab).',
  '',
  '**Kde to stojí**',
  'Úkol je uzavřený (Closed).',
  '',
  '**Co už padlo**',
  '- Editor v gridu (`Grid.Component.Editor`) byl přepracován.',
  '- V revizi 37156 bylo nasazeno řešení funkční ve **všech** prohlížečích.',
  '',
  '**Další krok**',
  'Žádné další kroky. <img src=x onerror=alert(1)> <script>alert(2)</script>'
].join('\n');

const dom = new JSDOM(`<!doctype html><html><head>
  <meta name="csrf-token" content="tok">
</head><body>
  <div id="content">
    <div class="contextual next-prev-links"><a href="#">prev</a></div>
    <div class="contextual">
      <a class="icon icon-edit" href="#">Upravit</a>
      <a class="icon icon-time-add" href="#">Zapsat čas</a>
      <a class="icon icon-fav-off" href="#">Sledovat</a>
    </div>
    <div class="details">
      <a href="#" class="icon icon-ai-wand ai-assistant-summary-link" data-raa="summary"
         data-issue-id="147" data-issue-label="#147: Test úkolu"
         data-working="Generuji shrnutí…">AI Summarizer</a>
    </div>
  </div>
</body></html>`, { url: 'http://localhost:3080/issues/147', pretendToBeVisual: true, runScripts: 'outside-only' });

const w = dom.window;
w.RAA_CONFIG = {
  base: '', suggestPath: '/ai_assistant/suggest', summaryPath: '/ai_assistant/summary',
  i18n: { close: 'Zavřít', summaryTitle: 'Shrnutí úkolu %{issue}' }
};

let fetchCalls = 0;
w.fetch = function (url) {
  fetchCalls++;
  return Promise.resolve({ ok: true, status: 200, json: () => Promise.resolve({ text: SAMPLE }) });
};

// Spusti plugin v kontexte stránky.
w.eval(fs.readFileSync(PLUGIN_JS, 'utf8'));

const doc = w.document;
const results = [];
function check(name, cond, extra) {
  results.push((cond ? '  OK   ' : '  !! CHYBA ') + name + (extra ? '  → ' + extra : ''));
}

const bar = doc.querySelectorAll('#content > .contextual')[1];
const link = doc.querySelector('a[data-raa="summary"]');

// Presun tlačidla beží až v DOMContentLoaded (v prehliadači sa plugin načítava
// na konci <body>, kedy je readyState ešte 'loading'), takže ho tu musíme dobehnúť.
doc.dispatchEvent(new w.Event('DOMContentLoaded', { bubbles: true }));

// --- 1. presun tlačidla do lišty akcií ---
check('tlačidlo je v lište akcií', link.parentNode === bar);
check('nie je v next-prev-links', !doc.querySelector('.next-prev-links a[data-raa="summary"]'));
const order = Array.from(bar.children).map(function (el) {
  return el.dataset.raa === 'summary' ? 'SUMMARIZER' : el.textContent.trim();
});
check('poradie Upravit → Summarizer → Zapsat čas',
      order.join(' | ') === 'Upravit | SUMMARIZER | Zapsat čas | Sledovat', order.join(' | '));
check('data-raa-placed nastavené', link.dataset.raaPlaced === '1');

// --- 2. klik otvorí overlay so stavom ---
link.dispatchEvent(new w.MouseEvent('click', { bubbles: true, cancelable: true }));
const overlay = doc.getElementById('raa-overlay');
const body = doc.getElementById('raa-body');
check('overlay existuje a je viditeľný', overlay && overlay.style.display === 'flex');
check('nadpis okna doplnený', doc.getElementById('raa-title').textContent === 'Shrnutí úkolu #147: Test úkolu',
      doc.getElementById('raa-title').textContent);
check('role=dialog + aria-modal',
      doc.getElementById('raa-box').getAttribute('role') === 'dialog' &&
      doc.getElementById('raa-box').getAttribute('aria-modal') === 'true');
check('stav "Generuji shrnutí…" ako text', body.textContent.indexOf('Generuji shrnutí') === 0);
check('fetch odoslaný raz', fetchCalls === 1, String(fetchCalls));

setTimeout(function () {
  // --- 3. vykreslenie zhrnutia ---
  const heads = body.querySelectorAll('h4.raa-h');
  const items = body.querySelectorAll('ul.raa-list li');
  check('nadpisy sú <strong>/<h4>, nie **text**', heads.length === 4, heads.length + ' nadpisov');
  check('prvý nadpis bez zvezdičiek', heads[0] && heads[0].textContent === 'O co jde',
        heads[0] && JSON.stringify(heads[0].textContent));
  check('žiadne ** v zobrazenom texte', body.textContent.indexOf('**') === -1);
  check('odrážky sú <li>', items.length === 2, items.length + ' položiek');
  check('bold vnútri odrážky', items[1] && items[1].querySelector('strong') &&
        items[1].querySelector('strong').textContent === 'všech');
  check('`kód` je <code>', body.querySelector('code') &&
        body.querySelector('code').textContent === 'Grid.Component.Editor');
  check('trieda raa-rich pridaná', body.classList.contains('raa-rich'));

  // --- 4. bezpečnosť: HTML z modelu sa NESMIE vykonať ---
  check('žiadny <img> z modelu', body.querySelector('img') === null);
  check('žiadny <script> z modelu', body.querySelector('script') === null);
  check('HTML zostalo textom', body.textContent.indexOf('<img src=x onerror=alert(1)>') !== -1);

  // --- 5. zatváranie ---
  // Telo musí byť fokusovateľné (scrollovanie klávesnicou) a Tab nesmie
  // vypadnúť z okna na stránku pod ním.
  check('telo je fokusovateľné (tabindex)', body.getAttribute('tabindex') === '0');
  check('telo má aria-live', body.getAttribute('aria-live') === 'polite');
  doc.getElementById('raa-close').focus();
  doc.dispatchEvent(new w.KeyboardEvent('keydown', { key: 'Tab', bubbles: true }));
  check('Tab z krížika ide na telo', doc.activeElement === body,
        doc.activeElement && doc.activeElement.id);
  doc.dispatchEvent(new w.KeyboardEvent('keydown', { key: 'Tab', bubbles: true }));
  check('Tab z tela sa vráti na krížik', doc.activeElement === doc.getElementById('raa-close'),
        doc.activeElement && doc.activeElement.id);

  doc.dispatchEvent(new w.KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
  check('Esc zatvorí overlay', overlay.style.display === 'none');

  link.dispatchEvent(new w.MouseEvent('click', { bubbles: true, cancelable: true }));
  check('druhý klik znova otvorí', overlay.style.display === 'flex');
  overlay.dispatchEvent(new w.MouseEvent('mousedown', { bubbles: true }));
  check('klik mimo zatvorí', overlay.style.display === 'none');

  link.dispatchEvent(new w.MouseEvent('click', { bubbles: true, cancelable: true }));
  doc.getElementById('raa-close').dispatchEvent(new w.MouseEvent('click', { bubbles: true }));
  check('krížik zatvorí', overlay.style.display === 'none');

  console.log(results.join('\n'));
  const failed = results.filter(function (r) { return r.indexOf('CHYBA') !== -1; }).length;
  console.log('\n' + (failed ? failed + ' TESTOV ZLYHALO' : 'vsetkych ' + results.length + ' testov OK'));
  process.exit(failed ? 1 : 0);
}, 50);
