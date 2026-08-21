// Test klientskej časti REŽIMU PLÁNU: spustí SKUTOČNÝ ai_assistant.js v jsdom,
// klikne na prútik v hlavičke a skontroluje výsledný DOM. `fetch` je stubnutý,
// takže nič nikam nechodí a nestojí to žiadne volanie do Gemini.
//
// Spustenie (jsdom nie je závislosť pluginu — berieme ho z monorepa theprevio):
//   NODE_PATH=C:/Users/marti/theprevio/node_modules node extra/plan_test.js
//
// Samostatný súbor od overlay_test.js zámerne: plán potrebuje úplne inú fixture
// (hlavička s #top-menu, žiadna úloha) a overuje sa v ňom niečo iné — okno bez
// formulára, zoznam projektov, plán o viacerých úlohách a sprievodca zakladaním.
const fs = require('fs');
const path = require('path');
const { JSDOM } = require('jsdom');

const PLUGIN_JS = path.join(__dirname, '..', 'assets', 'javascripts', 'ai_assistant.js');
const QUEUE_KEY = 'raa.plan.queue';

const PROJECTS = {
  projects: [
    { id: 34, name: 'Reservations', subtasks: true },
    { id: 12, name: 'Channel Manager', subtasks: true },
    { id: 99, name: 'Billing', subtasks: false }
  ],
  current: 34
};

// XSS pokus je v KAŽDOM textovom poli, ktoré ide od modelu.
const XSS = '<img src=x onerror=alert(1)> <script>alert(2)</script>';

const PLAN = {
  plan: {
    summary: '**Plán** je na tri kroky.\n- najprv databáza\n- potom API\n' + XSS,
    project_id: 34, project_name: 'Reservations',
    use_parent: true, subtasks_allowed: true,
    issues: [
      { subject: 'Support multiple guests ' + XSS, description: '**Where?** Reservations ' + XSS,
        tracker_id: 1, tracker_name: 'Feature', category_id: 5,
        category_name: 'RESERVATION - GUESTS', priority_id: 2, priority_name: 'Normal',
        custom_field_values: { '58': '109' },
        custom_field_names: [{ name: 'Project Manager', value: 'Novák Jan' }],
        project_id: 34 },
      { subject: 'Update database schema', description: 'short body',
        tracker_id: 1, tracker_name: 'Feature', priority_id: 2, priority_name: 'Normal',
        project_id: 34 },
      { subject: 'Extend partner API', description: 'short body',
        tracker_id: 1, tracker_name: 'Feature', priority_id: 2, priority_name: 'Normal',
        project_id: 34 }
    ],
    similar_issues: [{ id: 123, subject: 'Older guest task', reason: 'rovnaká oblasť' }],
    questions: ['Ktoré API verzie?']
  },
  project: { id: 34, name: 'Reservations', changed: false,
             reason: 'Zadanie sa týka rezervácií a hostí.' }
};

const results = [];
function check(name, cond, extra) {
  results.push((cond ? '  OK   ' : '  !! CHYBA ') + name + (extra ? '  → ' + extra : ''));
}

const I18N = {
  close: 'Zavrieť', cancel: 'Cancel',
  draftSimilar: 'Možné duplicity', draftQuestions: 'Doplňujúce otázky', draftAnswer: 'Odpoveď',
  draftProjectChanged: 'Projekt zmenený na %{project}',
  labels: { project: 'Projekt', subject: 'Názov', tracker: 'Tracker',
            category: 'Kategória', priority: 'Priorita' },
  plan: {
    title: 'AI issue creator', inputLabel: 'Čo treba urobiť?',
    placeholder: 'Opíš to vlastnými slovami…', projectLock: 'Nemeniť projekt',
    submit: 'See AI suggestion', refine: 'Prepočítať s doplnením', accept: 'Accept',
    working: 'Pripravujem návrh plánu…', heading: 'Návrh plánu',
    parent: 'Nadradená úloha', subtask: 'Podúloha', standalone: 'Samostatná úloha',
    noSubtasks: 'V projekte %{project} nemáš právo spravovať podúlohy.',
    empty: 'Najprv opíš, čo treba urobiť.', noResult: 'AI nevrátila žiadnu úlohu.',
    queueProgress: 'AI plán: založené %{done} zo %{total}',
    queueNext: 'Ďalšia: %{subject}', queueGo: 'Predvyplniť ďalšiu úlohu',
    queueSkip: 'Preskočiť', queueCancel: 'Zrušiť plán', queueDismiss: 'Skryť',
    queueDone: 'Hotovo — plán je založený.',
    queueNoParent: 'Nadradená úloha nebola založená.',
    queueParentMissing: 'Redmine nezobrazil pole nadradenej úlohy.'
  }
};

function makeDom(html, url, planResponse) {
  const dom = new JSDOM(html, { url: url, pretendToBeVisual: true, runScripts: 'outside-only' });
  const w = dom.window;
  w.RAA_CONFIG = {
    base: '', planPath: '/ai_assistant/plan_issues',
    planContextPath: '/ai_assistant/plan_context', projectId: 34, i18n: I18N
  };
  const calls = [];
  w.fetch = function (url, opts) {
    calls.push({ url: String(url), body: opts && opts.body ? JSON.parse(opts.body) : null });
    const data = String(url).indexOf('plan_context') !== -1 ? PROJECTS : (planResponse || {});
    return Promise.resolve({ ok: true, status: 200, json: () => Promise.resolve(data) });
  };
  /* `location.assign` sa v jsdom stubnut NEDA (je unforgeable), takze navigacia
   * sama sa tu overit neda — jsdom ju ohlasi ako „Not implemented: navigation".
   * Overuje sa preto to, co pozorovatelne JE: stav fronty v sessionStorage
   * a `href` odkazu „Predvyplnit dalsiu ulohu". */
  w.eval(fs.readFileSync(PLUGIN_JS, 'utf8'));
  return { w, doc: w.document, calls };
}

const HEADER = `<div id="top-menu">
    <div id="account"><ul>
      <li><a href="#" class="raa-plan-link" data-raa="plan">AI issue creator</a></li>
      <li><a href="/my/account" class="my-account">My account</a></li>
    </ul></div>
    <div id="loggedas">Logged in as <a href="/users/257">mkopac</a></div>
  </div>`;

/* ======================= FIXTURE 1 — okno a plán ======================= */
const PAGE_MY = `<!doctype html><html><head><meta name="csrf-token" content="tok"></head>
<body>${HEADER}<div id="content"><h2>My page</h2></div></body></html>`;

const F1 = makeDom(PAGE_MY, 'http://localhost:3080/my/page', PLAN);

/* Presun prútika beží v `init()`, teda na `DOMContentLoaded`. V jsdom ho
 * vyvoláme ručne — inak by sa testovala stránka, ktorá sa nikdy nedonačítala. */
F1.doc.dispatchEvent(new F1.w.Event('DOMContentLoaded', { bubbles: true }));

const link = F1.doc.querySelector('a[data-raa="plan"]');
check('prútik je v hlavičke', !!link);
/* Prútik patrí VĽAVO od ikonky osoby, teda pred `#loggedas`. Server ho vykresľuje
 * do `#account`, ktorý téma posiela až za meno, takže ho JS presúva o úroveň vyššie. */
check('prútik je priamo v #top-menu',
  link && link.parentNode === F1.doc.getElementById('top-menu'),
  link && link.parentNode && link.parentNode.id);
check('prútik stojí PRED menom prihláseného',
  link && link.nextElementSibling === F1.doc.getElementById('loggedas'),
  link && link.nextElementSibling && link.nextElementSibling.id);
check('prázdne <li> po prútiku zaniklo',
  F1.doc.querySelectorAll('#account li').length === 1,
  String(F1.doc.querySelectorAll('#account li').length));

const ev = new F1.w.MouseEvent('click', { bubbles: true, cancelable: true });
link.dispatchEvent(ev);
// Odkaz je href="#" — bez preventDefault by stránka odskočila na začiatok.
check('klik je defaultPrevented', ev.defaultPrevented);
check('okno sa otvorilo', (F1.doc.getElementById('raa-pl-overlay') || {}).hidden === false);
check('role=dialog + aria-modal', (() => {
  const b = F1.doc.getElementById('raa-pl-box');
  return b && b.getAttribute('role') === 'dialog' && b.getAttribute('aria-modal') === 'true';
})());
check('telo je fokusovateľné + aria-live', (() => {
  const b = F1.doc.getElementById('raa-pl-body');
  return b && b.getAttribute('tabindex') === '0' && b.getAttribute('aria-live') === 'polite';
})());

const input = F1.doc.getElementById('raa-pl-input');
const submit = F1.doc.getElementById('raa-pl-submit');
check('fokus je vo vstupnom poli', F1.doc.activeElement === input);
check('submit je zakázaný, kým je pole prázdne', submit.disabled === true);
/* Projekt sa pri prvom zadaní nevyberá — určuje ho AI podľa obsahu. Vyberať ho
 * dopredu znamenalo hádať a model to bral ako pokyn, kam úlohu napasovať. */
check('projekt sa pri prvom zadaní nevyberá', F1.doc.getElementById('raa-pl-row').hidden === true);

input.value = 'viac hosti v rezervacii';
input.dispatchEvent(new F1.w.Event('input', { bubbles: true }));
check('po vpísaní sa submit povolí', submit.disabled === false);

setTimeout(() => {
  const sel = F1.doc.getElementById('raa-pl-project');
  check('select má ponúknuté projekty', sel.options.length === 3, sel.options.length + '');
  check('default je projekt stránky', sel.value === '34', sel.value);
  check('príznak podúloh je na položkách',
    sel.querySelector('option[value="99"]').dataset.subtasks === '0');

  submit.click();

  setTimeout(() => {
    const body = F1.doc.getElementById('raa-pl-body');
    const cards = F1.doc.querySelectorAll('.raa-pl-card');
    check('plán sa vykreslil ako karty', cards.length === 3, cards.length + ' kariet');
    check('prvá karta je nadradená úloha', cards[0].dataset.role === 'parent');
    check('ostatné sú podúlohy',
      cards[1].dataset.role === 'subtask' && cards[2].dataset.role === 'subtask');
    check('súhrn je vyrenderovaný Markdown',
      !!F1.doc.querySelector('.raa-pl-summary .raa-h, .raa-pl-summary .raa-list'),
      (F1.doc.querySelector('.raa-pl-summary') || {}).className);
    check('karta má tracker a kategóriu',
      cards[0].querySelector('.raa-dm-summary').textContent.indexOf('Feature') !== -1);
    check('duplicity sú odkazy', !!body.querySelector('a[href*="/issues/123"]'));
    check('otázka má políčko', F1.doc.querySelectorAll('.raa-pl-answer').length === 1);
    check('Accept je viditeľný', F1.doc.getElementById('raa-pl-accept').hidden === false);
    check('submit sa premenoval na doplnenie', submit.textContent === I18N.plan.refine,
      submit.textContent);
    check('po návrhu sa projekt dá opraviť', F1.doc.getElementById('raa-pl-row').hidden === false);
    check('dôvod výberu projektu je vidieť', (() => {
      const r = F1.doc.getElementById('raa-pl-project-reason');
      return r && r.hidden === false && r.textContent.indexOf('rezervácií') !== -1;
    })());
    // Od návrhu ďalej je hlavný obsah okna plán, nie písanie.
    check('vstupné pole sa zmenšilo',
      F1.doc.getElementById('raa-pl-composer').classList.contains('raa-pl-compact') &&
      F1.doc.getElementById('raa-pl-input').rows === 1);

    // XSS: nič z modelu sa nesmie stať elementom.
    check('žiadny <img> z modelu', body.querySelector('img') === null);
    check('žiadny <script> z modelu', body.querySelector('script') === null);
    check('HTML z modelu zostalo textom', body.textContent.indexOf('onerror=alert(1)') !== -1);

    // Druhé kolo: odpoveď na otázku + transkript oboch strán.
    const answer = F1.doc.querySelector('.raa-pl-answer');
    answer.value = 'v2 aj v3';
    answer.dispatchEvent(new F1.w.Event('input', { bubbles: true }));
    check('odpoveď na otázku povolí odoslanie', submit.disabled === false);
    submit.click();

    setTimeout(() => {
      const last = F1.calls[F1.calls.length - 1];
      check('druhé kolo posiela celý transkript', (last.body.messages || []).length >= 3,
        (last.body.messages || []).length + ' správ');
      check('transkript má obe role',
        last.body.messages.some((m) => m.role === 'user') &&
        last.body.messages.some((m) => m.role === 'ai'));
      check('odpoveď na otázku je v transkripte',
        JSON.stringify(last.body.messages).indexOf('v2 aj v3') !== -1);
      check('pôvodné zadanie ide ako input',
        last.body.input === 'viac hosti v rezervacii', last.body.input);
      check('project_id sa neposiela, kým nie je zamknutý',
        last.body.project_id === null && last.body.lock_project === '0',
        JSON.stringify(last.body.project_id) + ' / ' + last.body.lock_project);
      /* Transkript zobrazuje len vstupy človeka — odtlačok plánu od AI je
       * v `messages` pre model, ale vypísaný by bol len duplicitou toho, čo je
       * pod ním vykreslené ako karty. */
      check('transkript zobrazuje vstupy človeka',
        F1.doc.querySelectorAll('.raa-pl-turn.raa-pl-user').length === 2,
        F1.doc.querySelectorAll('.raa-pl-turn').length + ' turnov');
      check('transkript nezobrazuje odtlačok AI',
        F1.doc.querySelectorAll('.raa-pl-turn.raa-pl-ai').length === 0);

      setTimeout(() => {
        F1.doc.getElementById('raa-pl-accept').click();

        const raw = F1.w.sessionStorage.getItem(QUEUE_KEY);
        const q = raw ? JSON.parse(raw) : null;
        check('Accept postavil frontu', !!q && q.items.length === 3);
        check('fronta začína na nule', q && q.cursor === 0 && q.awaiting === 0);
        check('fronta si pamätá hierarchiu', q && q.useParent === true);
        check('okno sa po Accept zavrelo',
          F1.doc.getElementById('raa-pl-overlay').hidden === true);

        /* Navigáciu samotnú jsdom zachytiť nedovolí (`location.assign` je
         * unforgeable), takže sa overuje to, čo pozorovateľné JE: stav fronty.
         * URL sa kontroluje v druhej fixture, kde je v `href` odkazu. */
        check('položky nesú projekt aj tracker',
          q.items.every(function (i) {
            return String(i.project_id) === '34' && String(i.tracker_id) === '1';
          }));
        check('prvá položka je nadradená úloha', q.items[0].subject.indexOf('Support multiple') === 0);

        /* Jedna úloha nie je čo sprevádzať: panel „1 z 1 založené" a tlačidlo na
   * zrušenie plánu, ktorý už neexistuje, by boli len na obtiaž. */
  const ONE = makeDom(PAGE_MY, 'http://localhost:3080/my/page',
    { plan: Object.assign({}, PLAN.plan, { use_parent: false, questions: [],
        issues: [PLAN.plan.issues[0]] }),
      project: { id: 34, name: 'Reservations', changed: false } });
  ONE.doc.querySelector('a[data-raa="plan"]').click();
  setTimeout(function () {
    const oi = ONE.doc.getElementById('raa-pl-input');
    oi.value = 'jedna vec';
    oi.dispatchEvent(new ONE.w.Event('input', { bubbles: true }));
    ONE.doc.getElementById('raa-pl-submit').click();
    setTimeout(function () {
      ONE.doc.getElementById('raa-pl-accept').click();
      check('jedna úloha nezakladá frontu',
        ONE.w.sessionStorage.getItem(QUEUE_KEY) === null);
      runFixture2();
    }, 40);
  }, 40);
      }, 30);
    }, 40);
  }, 40);
}, 40);

/* ============ FIXTURE 2 — sprievodca zakladaním (panel a fronta) ============ */
/* `awaiting: 0` + `submitted: true` znamená „navigovali sme na formulár prvej
 * položky A ten formulár sa odoslal". Obe podmienky sú potrebné: bez `submitted`
 * by sa za založenie počítala aj obyčajná odbočka na existujúcu úlohu (viď
 * testy „odbočka" nižšie). */
function queueFixture(over) {
  return Object.assign({
    v: 1, created: Date.now(), useParent: true, parentIssueId: null, cursor: 0, awaiting: 0,
    submitted: true,
    items: [
      { subject: 'Parent task', description: 'x', tracker_id: '1', category_id: '5',
        priority_id: '2', custom_field_values: { '58': '109' }, project_id: '34', state: 'pending' },
      { subject: 'Subtask one', description: 'y', tracker_id: '1', project_id: '34',
        custom_field_values: {}, state: 'pending' },
      { subject: 'Subtask two', description: 'z', tracker_id: '1', project_id: '34',
        custom_field_values: {}, state: 'pending' }
    ]
  }, over || {});
}

const ISSUE_PAGE = `<!doctype html><html><head><meta name="csrf-token" content="tok"></head>
<body>${HEADER}<div id="content"><h2>Feature #12345</h2>
  <div class="issue"><p>detail</p></div>
</div></body></html>`;

const NEW_PAGE = (withParentField) => `<!doctype html><html><head>
<meta name="csrf-token" content="tok"></head>
<body>${HEADER}<div id="content"><h2>New issue</h2>
  <form id="issue-form"><div id="all_attributes">
    <input id="issue_subject"><textarea id="issue_description"></textarea>
    <select id="issue_project_id"><option value="34" selected>Reservations</option></select>
    <select id="issue_tracker_id"><option value="1">Feature</option></select>
    ${withParentField ? '<input id="issue_parent_issue_id">' : ''}
  </div></form>
</div></body></html>`;

function withQueue(html, url, q) {
  const f = makeDom(html, url, PLAN);
  f.w.sessionStorage.setItem(QUEUE_KEY, JSON.stringify(q));
  // initPlanQueue beží pri načítaní; v jsdom ho vyvoláme druhým DOMContentLoaded.
  f.doc.dispatchEvent(new f.w.Event('DOMContentLoaded', { bubbles: true }));
  return f;
}

function runFixture2() {
  // a) po založení nadradenej úlohy stojíme na jej detaile
  const A = withQueue(ISSUE_PAGE, 'http://localhost:3080/issues/12345', queueFixture());
  const panel = A.doc.getElementById('raa-plan-queue');
  check('panel sa vykreslil', !!panel);
  check('panel je MIMO #all_attributes', panel && panel.closest('#all_attributes') === null);
  check('panel je pod nadpisom stránky',
    panel && panel.previousElementSibling && panel.previousElementSibling.tagName === 'H2');
  const qA = JSON.parse(A.w.sessionStorage.getItem(QUEUE_KEY));
  check('nadradená úloha označená ako založená', qA.items[0].state === 'created');
  check('parentIssueId prevzatý z adresy', qA.parentIssueId === '12345', qA.parentIssueId);
  check('cursor sa posunul', qA.cursor === 1);
  check('počítadlo hlási 1 z 3', panel.textContent.indexOf('1 zo 3') !== -1,
    panel.textContent.slice(0, 40));
  check('panel hlási ďalšiu úlohu', panel.textContent.indexOf('Subtask one') !== -1);

  const goLink = A.doc.getElementById('raa-plan-queue-go');
  check('Predvyplniť ďalšiu je ODKAZ (Ctrl+klik do nového panelu)',
    goLink && goLink.tagName === 'A' && !!goLink.getAttribute('href'));
  const urlB = (goLink && goLink.getAttribute('href')) || '';
  goLink.click();
  check('podúloha nesie parent_issue_id',
    urlB.indexOf('issue%5Bparent_issue_id%5D=12345') !== -1, urlB.slice(-90));
  check('podúloha nesie back_url na nadradenú',
    urlB.indexOf('back_url=%2Fissues%2F12345') !== -1);

  // b) na formulári novej úlohy je panel len prehľad
  const B = withQueue(NEW_PAGE(true), 'http://localhost:3080/projects/reservations/issues/new',
    queueFixture({ cursor: 1, awaiting: null, parentIssueId: '12345',
                   items: queueFixture().items.map((it, i) =>
                     Object.assign({}, it, { state: i === 0 ? 'created' : 'pending' })) }));
  const pB = B.doc.getElementById('raa-plan-queue');
  check('na formulári je panel prehľad', !!pB);
  check('na formulári NIE JE tlačidlo Predvyplniť',
    B.doc.getElementById('raa-plan-queue-go') === null);
  check('na formulári je Preskočiť aj Zrušiť',
    !!B.doc.getElementById('raa-plan-queue-skip') && !!B.doc.getElementById('raa-plan-queue-cancel'));

  // c) chýbajúce pole nadradenej úlohy = tichý zahod pri chýbajúcom práve
  const C = withQueue(NEW_PAGE(false), 'http://localhost:3080/projects/reservations/issues/new',
    queueFixture({ cursor: 1, awaiting: null, parentIssueId: '12345' }));
  check('chýbajúce pole parenta sa ohlási',
    C.doc.getElementById('raa-plan-queue').textContent
      .indexOf('nezobrazil pole nadradenej') !== -1);

  // d) preskočenie nadradenej úlohy
  const D = withQueue(ISSUE_PAGE, 'http://localhost:3080/issues/999',
    queueFixture({ cursor: 1, awaiting: null, parentIssueId: null,
                   items: queueFixture().items.map((it, i) =>
                     Object.assign({}, it, { state: i === 0 ? 'skipped' : 'pending' })) }));
  check('preskočená nadradená úloha sa ohlási',
    D.doc.getElementById('raa-plan-queue').textContent
      .indexOf('Nadradená úloha nebola založená') !== -1);

  // e) zrušenie plánu
  const E = withQueue(ISSUE_PAGE, 'http://localhost:3080/issues/12345', queueFixture());
  E.doc.getElementById('raa-plan-queue-cancel').click();
  check('Zrušiť plán odstráni panel', E.doc.getElementById('raa-plan-queue') === null);
  check('Zrušiť plán vyčistí úložisko', E.w.sessionStorage.getItem(QUEUE_KEY) === null);

  // f) prekročené TTL
  const G = withQueue(ISSUE_PAGE, 'http://localhost:3080/issues/12345',
    queueFixture({ created: Date.now() - 3 * 60 * 60 * 1000 }));
  check('stará fronta sa nevykreslí', G.doc.getElementById('raa-plan-queue') === null);
  check('stará fronta sa vyčistí', G.w.sessionStorage.getItem(QUEUE_KEY) === null);

  // g) hostilná fronta podstrčená z konzoly
  const H = withQueue(ISSUE_PAGE, 'http://localhost:3080/issues/12345',
    { v: 1, created: Date.now(), cursor: 0, awaiting: 0, useParent: false,
      items: [{ subject: 'x', project_id: '1;alert(1)', tracker_id: '<img>',
                custom_field_values: {}, state: 'pending' }] });
  check('hostilná fronta sa nevykreslí', H.doc.getElementById('raa-plan-queue') === null);
  check('hostilná fronta sa vyčistí', H.w.sessionStorage.getItem(QUEUE_KEY) === null);

  /* g2) plán v projekte, kde človek nesmie spravovať podúlohy. Serverovo to
   *     vynucuje `resolve_plan`; okno o tom musí POVEDAŤ — inak by človek
   *     nechápal, prečo sú úlohy samostatné, a hľadal by chybu. */
  const NP = makeDom(PAGE_MY, 'http://localhost:3080/my/page',
    { plan: Object.assign({}, PLAN.plan, { use_parent: false, subtasks_allowed: false }),
      project: { id: 99, name: 'Billing', changed: true } });
  NP.doc.querySelector('a[data-raa="plan"]').click();
  setTimeout(function () {
    const inp = NP.doc.getElementById('raa-pl-input');
    inp.value = 'nieco';
    inp.dispatchEvent(new NP.w.Event('input', { bubbles: true }));
    NP.doc.getElementById('raa-pl-submit').click();
    setTimeout(function () {
      const txt = NP.doc.getElementById('raa-pl-body').textContent;
      check('bez práva okno upozorní', txt.indexOf('nemáš právo spravovať podúlohy') !== -1);
      check('bez práva sú karty samostatné',
        NP.doc.querySelectorAll('.raa-pl-card[data-role="standalone"]').length === 3);
      check('žiadna karta nie je podúloha',
        NP.doc.querySelectorAll('.raa-pl-card[data-role="subtask"]').length === 0);
      check('zmena projektu sa ohlási', txt.indexOf('Projekt zmenený na Billing') !== -1);
      finish();
    }, 40);
  }, 40);
}

function finish() {
  /* i) hotový plán — nie je čo zrušiť, takže tlačidlo je „Skryť". */
  const DONE = withQueue(ISSUE_PAGE, 'http://localhost:3080/issues/777',
    queueFixture({ cursor: 3, awaiting: null, parentIssueId: '12345',
                   items: queueFixture().items.map(function (it) {
                     return Object.assign({}, it, { state: 'created' });
                   }) }));
  const pDone = DONE.doc.getElementById('raa-plan-queue');
  check('hotový plán hlási dokončenie',
    pDone.textContent.indexOf('Hotovo') !== -1, pDone.textContent.slice(0, 50));
  check('hotový plán nemá Predvyplniť',
    DONE.doc.getElementById('raa-plan-queue-go') === null);
  check('hotový plán má Skryť, nie Zrušiť plán',
    DONE.doc.getElementById('raa-plan-queue-cancel').textContent === 'Skryť',
    DONE.doc.getElementById('raa-plan-queue-cancel').textContent);

  // h) plán bez hierarchie
  const I = withQueue(ISSUE_PAGE, 'http://localhost:3080/issues/555',
    queueFixture({ useParent: false }));
  const urlI = I.doc.getElementById('raa-plan-queue-go').getAttribute('href') || '';
  check('bez hierarchie žiadny parent_issue_id', urlI.indexOf('parent_issue_id') === -1);

  /* j) ODBOČKA namiesto Create. Človek stojí na formulári nadradenej úlohy
   * (`awaiting: 0`), ale namiesto odoslania klikne na existujúcu úlohu #49286.
   * Nič sa nezaložilo, takže sa nesmie nič započítať — inak by sa číslo cudzej
   * úlohy stalo nadradenou a podúlohy by sa naviazali na ňu. */
  const J = withQueue(ISSUE_PAGE, 'http://localhost:3080/issues/49286',
    queueFixture({ submitted: false }));
  const qJ = JSON.parse(J.w.sessionStorage.getItem(QUEUE_KEY));
  check('odbočka nezaloží úlohu', qJ.items[0].state === 'pending', qJ.items[0].state);
  check('odbočka neurobí z cudzej úlohy nadradenú', qJ.parentIssueId === null, qJ.parentIssueId);
  check('odbočka neposunie cursor', qJ.cursor === 0, String(qJ.cursor));
  check('odbočka nechá awaiting nedotknuté', qJ.awaiting === 0, String(qJ.awaiting));

  /* k) Odoslanie formulára je to, čo frontu odistí — nie adresa. */
  const K = withQueue(NEW_PAGE(true), 'http://localhost:3080/projects/reservations/issues/new',
    queueFixture({ submitted: false }));
  const beforeK = JSON.parse(K.w.sessionStorage.getItem(QUEUE_KEY));
  check('pred odoslaním nie je fronta odistená', beforeK.submitted === false);
  K.doc.getElementById('issue-form').dispatchEvent(
    new K.w.Event('submit', { bubbles: true, cancelable: true }));
  const afterK = JSON.parse(K.w.sessionStorage.getItem(QUEUE_KEY));
  check('odoslanie formulára frontu odistí', afterK.submitted === true);

  /* l) Validácia vrátila formulár: príznak sa musí zhasnúť, aby neplatil až pre
   * ďalšie, nesúvisiace prekliknutie na nejakú úlohu. */
  const L = withQueue(NEW_PAGE(true), 'http://localhost:3080/projects/reservations/issues/new',
    queueFixture({ submitted: true }));
  const qL = JSON.parse(L.w.sessionStorage.getItem(QUEUE_KEY));
  check('vrátený formulár príznak zhasne', qL.submitted === false, String(qL.submitted));

  /* m) A po odistení sa korektný tok chová ako predtým. */
  const M = withQueue(ISSUE_PAGE, 'http://localhost:3080/issues/50001',
    queueFixture({ submitted: true }));
  const qM = JSON.parse(M.w.sessionStorage.getItem(QUEUE_KEY));
  check('po odoslaní sa úloha započíta', qM.items[0].state === 'created');
  check('po odoslaní vznikne nadradená úloha', qM.parentIssueId === '50001', qM.parentIssueId);
  check('príznak sa po započítaní zhasne', qM.submitted === false);

  console.log(results.join('\n'));
  const bad = results.filter((r) => r.indexOf('CHYBA') !== -1).length;
  console.log(bad ? `\n${bad} TESTOV ZLYHALO` : `\nvsetkych ${results.length} testov OK`);
  process.exit(bad ? 1 : 0);
}
