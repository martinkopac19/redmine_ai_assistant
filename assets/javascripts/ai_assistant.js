/* Redmine AI Assistant (Previo)
 *
 * Jedna funkcia: vygenerovať návrh odpovede a vložiť ho do poľa komentára.
 * Text sa vždy len vloží — odosiela ho užívateľ, takže nikdy neodíde niečo,
 * čo nevidel.
 */
(function () {
  'use strict';

  var CFG = window.RAA_CONFIG || {};

  function csrfToken() {
    var meta = document.querySelector('meta[name="csrf-token"]');
    return meta ? meta.getAttribute('content') : '';
  }

  function post(path, payload, signal) {
    return fetch((CFG.base || '') + path, {
      method: 'POST',
      credentials: 'same-origin',
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'X-CSRF-Token': csrfToken()
      },
      body: JSON.stringify(payload),
      signal: signal || null
    }).then(function (res) {
      return res.json().catch(function () { return {}; }).then(function (data) {
        // Chyba prichádza ako HTTP 4xx/5xx s JSON správou, nie ako text návrhu.
        if (!res.ok) { throw new Error(data.error || ('HTTP ' + res.status)); }
        return data;
      });
    });
  }

  function setStatus(scope, message, isError) {
    var el = scope.querySelector('.ai-assistant-status');
    if (!el) { return; }
    el.textContent = message || '';
    el.classList.toggle('ai-assistant-error', !!isError);
  }

  /* Tlačidlo patrí vedľa "Add comment". To tlačidlo vytvára plugin
   * redmine_rich_editor (.re-comment-submit v .re-comment-box pod históriou),
   * a to až JS-om po načítaní stránky — preto to skúšame aj cez MutationObserver.
   *
   * Náš partial sa renderuje v jedinom hooku formulára úlohy, ktorý je vo
   * skrytom #update. Presunutím k "Add comment" sa tlačidlo zároveň stane
   * viditeľným bez klikania na Upraviť.
   *
   * Ak Rich Editor nie je aktívny, tlačidlo necháme tam, kde je — na spodné
   * Odoslať ho neposúvame, tam nemá zmysel. */
  function placeButton() {
    /* `:not(.ai-assistant-draft)` je dôležité: tlačidlo na predvyplnenie novej
     * úlohy má rovnaký obal `.ai-assistant-actions` (kvôli štýlom a zrušeniu),
     * ale patrí do formulára novej úlohy, nie ku komentáru. */
    var box = document.querySelector('.ai-assistant-actions:not(.ai-assistant-draft)');
    if (!box || box.dataset.raaPlaced === '1') { return true; }

    var addComment = document.querySelector('.re-comment-submit');
    if (!addComment || !addComment.parentNode) { return false; }

    addComment.parentNode.insertBefore(box, addComment.nextSibling);
    box.dataset.raaPlaced = '1';
    return true;
  }

  function watchForCommentBox() {
    if (placeButton()) { return; }

    var observer = new MutationObserver(function () {
      if (placeButton()) { observer.disconnect(); }
    });
    observer.observe(document.body || document.documentElement,
                     { childList: true, subtree: true });
    // Rich Editor sa nemusí namountovať vôbec — nedržíme observer navždy.
    setTimeout(function () { observer.disconnect(); }, 15000);
  }

  /* Tlačidlo "AI Summarizer" patrí do lišty akcií medzi Upraviť a Zapísať čas.
   * Lišta je Redmine partial `issues/_action_menu` BEZ hooku, takže sa tam
   * serverovo dostať nedá a presúvame ho JS-om.
   *
   * POZOR na selektor: `.contextual` je na stránke viackrát — lišta akcií,
   * `next-prev-links contextual` (odkazy predchádzajúca/ďalšia) a jeden v bloku
   * popisu. Berieme prvú, ktorá nie je next-prev-links. */
  function actionBar() {
    var bars = document.querySelectorAll('#content > .contextual');
    for (var i = 0; i < bars.length; i++) {
      if (!bars[i].classList.contains('next-prev-links')) { return bars[i]; }
    }
    return null;
  }

  function placeSummaryButton() {
    var link = document.querySelector('a[data-raa="summary"]');
    if (!link || link.dataset.raaPlaced === '1') { return; }

    var bar = actionBar();
    if (!bar) { return; }

    // Upraviť aj Zapísať čas sú podmienené právami, takže ani jedno tam nemusí
    // byť — preto reťaz fallbackov až po "prilep na konec".
    var logTime = bar.querySelector('a.icon-time-add');
    var edit = bar.querySelector('a.icon-edit');
    if (logTime) {
      bar.insertBefore(link, logTime);
    } else if (edit) {
      bar.insertBefore(link, edit.nextSibling);
    } else {
      bar.insertBefore(link, bar.firstChild);
    }
    link.dataset.raaPlaced = '1';
  }

  /* Prútik patrí VĽAVO od ikonky osoby. Server ho vykresľuje cez `account_menu`,
   * teda do `#account` — a ten téma flexboxom posiela až ZA meno prihláseného
   * (`#loggedas` má order 2, `#account` order 3). `order` medzi dvoma rôznymi
   * flex kontejnermi nefunguje, takže sa odkaz musí presunúť o úroveň vyššie,
   * medzi navigáciu a meno. Bez JS zostane tam, kde ho vykreslil server — hneď
   * za menom, čo je použiteľný fallback.
   *
   * Presúva sa samotný `<a>`, nie jeho `<li>`: `<li>` mimo `<ul>` by bolo
   * neplatné HTML. Prázdne `<li>` po ňom zaniká.
   *
   * Podmienka na `#loggedas` je zámerná: v téme, ktorá meno prihláseného
   * nevykresľuje, nie je k čomu prútik prilepiť a necháva sa, kde je. */
  function placePlanLink() {
    var link = document.querySelector('#top-menu a[data-raa="plan"]');
    if (!link || link.dataset.raaPlaced === '1') { return; }

    var topMenu = document.getElementById('top-menu');
    var loggedas = document.getElementById('loggedas');
    if (!topMenu || !loggedas || loggedas.parentNode !== topMenu) { return; }

    var li = link.closest('li');
    topMenu.insertBefore(link, loggedas);
    link.dataset.raaPlaced = '1';
    if (li && !li.children.length) { li.remove(); }
  }

  function init() {
    watchForCommentBox();
    placeSummaryButton();
    placePlanLink();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }

  /* POZOR: na stránke úlohy sú DVA editory Rich Editora — popisu a komentára —
   * a oba majú triedu `.re-editor`. Nescopovaný `.re-editor` vráti ten PRVÝ,
   * teda editor popisu (Rich Editor ho vkladá pred #issue_description_wiki,
   * vysoko na stránke). Jeho fokusnutie odscrolluje stránku nahor k popisu.
   *
   * Editor komentára je vždy vnútri `.re-comment-box`, ktorý Rich Editor vytvára
   * hneď za `#history`. */
  function commentEditable() {
    var box = document.querySelector('.re-comment-box');
    return box ? box.querySelector('[contenteditable="true"]') : null;
  }

  function focusQuietly(el) {
    // preventScroll: aj správny editor by inak stránku posunul na kurzor.
    try {
      el.focus({ preventScroll: true });
    } catch (e) {
      el.focus();
    }
  }

  /* Textarea #issue_notes je pri aktívnom Rich Editore skrytá, ale ten si
   * prepísal jej `value` setter tak, že zápis prepíše aj obsah editora.
   * Stačí teda nastaviť value; fokus dávame editoru, nie skrytému poľu. */
  function insertText(text) {
    var field = document.getElementById('issue_notes');
    if (!field) { return; }
    field.value = text;

    var editable = commentEditable();
    if (editable) {
      focusQuietly(editable);
    } else if (field.offsetParent !== null) {
      focusQuietly(field);
    }
  }

  /* Zrušenie generovania (missclick). Krížik je vedľa "Generujem…" a odpáli
   * AbortController, ktorý držíme na scope elemente.
   *
   * Pozn.: volanie u Gemini sa tým nezastaví — zahodíme len odpoveď, takže sa
   * do komentára nič nevloží. Spotrebované volanie z hodinového limitu preto
   * zostáva spotrebované. */
  function toggleCancel(scope, visible) {
    var x = scope.querySelector('.ai-assistant-cancel');
    if (x) { x.hidden = !visible; }
  }

  function abortPending(scope) {
    if (scope._raaAbort) {
      scope._raaAbort.abort();
      scope._raaAbort = null;
    }
  }

  document.addEventListener('click', function (event) {
    var scope;

    var cancelBtn = event.target.closest('.ai-assistant-cancel[data-raa="cancel"]');
    if (cancelBtn) {
      event.preventDefault();
      scope = cancelBtn.closest('.ai-assistant-actions');
      if (scope) { abortPending(scope); }
      return;
    }

    var btn = event.target.closest('.ai-assistant-btn[data-raa="suggest"]');
    if (!btn) { return; }
    event.preventDefault();

    scope = btn.closest('.ai-assistant-actions');
    if (!scope) { return; }

    // Aby po dvoch kliknutiach nevisela stará požiadavka.
    abortPending(scope);

    var controller = window.AbortController ? new window.AbortController() : null;
    scope._raaAbort = controller;

    btn.disabled = true;
    setStatus(scope, btn.getAttribute('data-working') || '', false);
    // Bez AbortControlleru sa zrušiť nedá, tak krížik ani neukazujeme.
    toggleCancel(scope, !!controller);

    post(CFG.suggestPath, { issue_id: scope.getAttribute('data-issue-id') },
         controller && controller.signal)
      .then(function (data) {
        insertText(data.text);
        setStatus(scope, '', false);
      })
      .catch(function (err) {
        // Zrušenie nie je chyba — status len zmizne, nič sa nevloží.
        if (err && err.name === 'AbortError') {
          setStatus(scope, '', false);
          return;
        }
        setStatus(scope, err.message, true);
      })
      .finally(function () {
        btn.disabled = false;
        toggleCancel(scope, false);
        if (scope._raaAbort === controller) { scope._raaAbort = null; }
      });
  });

  /* ------------------------------------------------------------------ *
   * AI Summarizer — overlay okno so zhrnutím úlohy.
   *
   * Zhrnutie sa iba zobrazuje; nikam sa nevkladá. Okno stavia JS (vzor
   * #rcp-overlay z redmine_command_palette), všetky selektory sú prefixované
   * `raa-`, aby nič neprebíjalo Redmine ani tému.
   * ------------------------------------------------------------------ */
  var ov = null;          // { overlay, box, title, body, close }
  var ovAbort = null;     // AbortController rozbehnutej požiadavky
  var ovOpener = null;    // tlačidlo, na ktoré sa má vrátiť fokus

  /* ---------------------------------------------------------------------------
   * Spoločný shell modálnych okien.
   *
   * Vznikol pri treťom okne: dve kópie sa dali strpieť, tri už nie. Fabrika
   * rieši to, čo je vo všetkých rovnaké (ARIA, krížik, klik do pozadia, Escape,
   * focus trap) a telo aj pätu necháva volajúcemu.
   *
   * `#raa-overlay` (zhrnutie) sa na fabriku ZÁMERNE nepresúva: prepína sa cez
   * `style.display`, nie cez `hidden`, a jeho chovanie je zamknuté v
   * extra/overlay_test.js. Prepisovať ho by bola zmena bez prínosu. Do registra
   * dialógov ho ale pridávame, aby klávesnicu obsluhovalo jedno miesto.
   * ------------------------------------------------------------------------- */

  /* Register otvorených okien. Escape a Tab obsluhuje VŽDY len to najvrchnejšie —
   * tri nezávislé keydown handlery by pri dvoch otvorených oknách zavreli obe. */
  var dialogs = [];

  function registerDialog(d) {
    dialogs.push(d);
    return d;
  }

  function topDialog() {
    for (var i = dialogs.length - 1; i >= 0; i--) {
      if (dialogs[i].isOpen()) { return dialogs[i]; }
    }
    return null;
  }

  /* Fokusovateľné prvky sa zisťujú AŽ pri stlačení Tab, nie pri stavbe okna:
   * telo sa prekresľuje (stav → návrh → otázky), takže staticky zapamätaný
   * zoznam by po prvom prekreslení ukazoval na prvky mimo DOM. */
  function focusables(box) {
    var sel = 'a[href],button:not([disabled]),input:not([disabled]),' +
              'select:not([disabled]),textarea:not([disabled]),[tabindex="0"]';
    /* Skryté prvky sa vynechávajú podľa atribútu `hidden` (aj na predkovi), nie
     * podľa `offsetParent`: tento kód sa testuje v jsdom, ktorý layout nepočíta
     * a `offsetParent` tam je vždy null — filter by prepustil len telo okna
     * a Tab by cyklil na jednom prvku. Okná pluginu skrývajú prvky výhradne
     * atribútom `hidden`, takže je to zároveň presnejšie. */
    return Array.prototype.filter.call(box.querySelectorAll(sel), function (el) {
      return !el.closest('[hidden]');
    });
  }

  function trapFocus(event, box) {
    var order = focusables(box);
    if (!order.length) { return; }

    event.preventDefault();
    var i = order.indexOf(document.activeElement);
    var next = event.shiftKey ? i - 1 : i + 1;
    if (next < 0) { next = order.length - 1; }
    if (next >= order.length) { next = 0; }
    focusQuietly(order[next]);
  }

  // Jediný klávesový handler pre všetky okná. Capture fáza, aby predbehol
  // jadrové handlery Redmine (rovnako to robí command palette).
  document.addEventListener('keydown', function (event) {
    var d = topDialog();
    if (!d) { return; }

    if (event.key === 'Escape') {
      event.preventDefault();
      event.stopPropagation();
      d.close(event);
      return;
    }
    if (event.key === 'Tab') { trapFocus(event, d.box); }
  }, true);

  /* Shell okna. Vracia prvky a `hide`/`show`; obsah tela a pätu plní volajúci.
   * `onClose` sa volá pri krížiku, Escape aj kliknutí do pozadia. */
  function buildDialog(prefix, titleText, onClose) {
    var overlay = document.createElement('div');
    overlay.id = prefix + '-overlay';
    overlay.hidden = true;

    var box = document.createElement('div');
    box.id = prefix + '-box';
    box.setAttribute('role', 'dialog');
    box.setAttribute('aria-modal', 'true');
    box.setAttribute('aria-labelledby', prefix + '-title');
    box.tabIndex = -1;

    var head = document.createElement('div');
    head.id = prefix + '-head';
    var title = document.createElement('h3');
    title.id = prefix + '-title';
    title.textContent = titleText || '';
    var close = document.createElement('button');
    close.type = 'button';
    close.id = prefix + '-close';
    close.setAttribute('aria-label', (CFG.i18n || {}).close || 'Close');
    close.title = close.getAttribute('aria-label');
    close.textContent = '×';
    head.appendChild(title);
    head.appendChild(close);

    var body = document.createElement('div');
    body.id = prefix + '-body';
    // Telo je scrollovateľné, takže musí byť fokusovateľné — inak sa dlhý obsah
    // nedá odscrollovať klávesnicou.
    body.tabIndex = 0;
    body.setAttribute('aria-live', 'polite');

    var foot = document.createElement('div');
    foot.id = prefix + '-foot';

    box.appendChild(head);
    box.appendChild(body);
    box.appendChild(foot);
    overlay.appendChild(box);
    document.body.appendChild(overlay);

    close.addEventListener('click', onClose);
    // Zámerne `e.target === overlay`, nie `contains`: inak by okno zavrelo aj
    // ťahanie kurzorom po texte vnútri.
    overlay.addEventListener('mousedown', function (e) {
      if (e.target === overlay) { onClose(e); }
    });

    var dlg = { overlay: overlay, box: box, head: head, title: title,
                body: body, foot: foot, close: close,
                isOpen: function () { return !overlay.hidden; } };
    registerDialog({ box: box, isOpen: dlg.isOpen, close: onClose });
    return dlg;
  }

  function buildOverlay() {
    if (ov) { return ov; }

    var overlay = document.createElement('div');
    overlay.id = 'raa-overlay';
    overlay.style.display = 'none';

    var box = document.createElement('div');
    box.id = 'raa-box';
    // Prístupnosť: command palette toto nemá, tu to robíme poriadne.
    box.setAttribute('role', 'dialog');
    box.setAttribute('aria-modal', 'true');
    box.setAttribute('aria-labelledby', 'raa-title');
    box.tabIndex = -1;

    var head = document.createElement('div');
    head.id = 'raa-head';

    var title = document.createElement('h3');
    title.id = 'raa-title';

    var close = document.createElement('button');
    close.type = 'button';
    close.id = 'raa-close';
    close.setAttribute('aria-label', CFG.i18n && CFG.i18n.close ? CFG.i18n.close : 'Close');
    close.title = close.getAttribute('aria-label');
    close.textContent = '×';

    var body = document.createElement('div');
    body.id = 'raa-body';
    // Telo je scrollovateľné, takže MUSÍ byť fokusovateľné — inak sa dlhé
    // zhrnutie nedá odscrollovať klávesnicou (div bez tabindex fokus nedostane).
    body.tabIndex = 0;
    // Obsah sa mení z „Generujem…" na zhrnutie — bez aria-live to čítač neoznámi.
    body.setAttribute('aria-live', 'polite');

    head.appendChild(title);
    head.appendChild(close);
    box.appendChild(head);
    box.appendChild(body);
    overlay.appendChild(box);
    document.body.appendChild(overlay);

    close.addEventListener('click', closeOverlay);
    // Klik mimo okna: kontrola na e.target === overlay, nie contains — inak by
    // zatváralo aj tahanie kurzorom po texte vnútri.
    overlay.addEventListener('mousedown', function (e) {
      if (e.target === overlay) { closeOverlay(); }
    });

    ov = { overlay: overlay, box: box, title: title, body: body, close: close };
    // Klávesnicu obsluhuje spoločný register (viď buildDialog) — toto okno má
    // vlastný mechanizmus viditeľnosti, preto si `isOpen` dodáva samo.
    registerDialog({ box: box, isOpen: overlayOpen, close: closeOverlay });
    return ov;
  }

  function overlayOpen() {
    return ov && ov.overlay.style.display !== 'none';
  }

  /* Model vracia Markdown (**nadpis**, `kód`, odrážky). Vykresľujeme ho tak, že
   * SKLADÁME DOM NODY — nikdy `innerHTML`. Výstup modelu je nedôveryhodný vstup
   * a `innerHTML` by z neho spravil HTML vrátane <script> a onerror atribútov.
   *
   * Zámerne podporujeme len to, čo zhrnutie naozaj používa: **bold**, `kód`,
   * odrážky a riadok, ktorý je celý bold (nadpis sekcie). Zvyšok Markdownu
   * zostane textom — to je bezpečnejšie než vlastný neúplný parser. */
  var INLINE_RE = /\*\*([^*]+)\*\*|`([^`]+)`/g;

  function appendInline(parent, text) {
    var last = 0;
    var m;
    INLINE_RE.lastIndex = 0;
    while ((m = INLINE_RE.exec(text)) !== null) {
      if (m.index > last) {
        parent.appendChild(document.createTextNode(text.slice(last, m.index)));
      }
      var isBold = m[1] !== undefined;
      var el = document.createElement(isBold ? 'strong' : 'code');
      el.textContent = isBold ? m[1] : m[2];
      parent.appendChild(el);
      last = m.index + m[0].length;
    }
    if (last < text.length) {
      parent.appendChild(document.createTextNode(text.slice(last)));
    }
  }

  function renderMarkdownish(container, text) {
    var lines = String(text || '').split(/\r?\n/);
    var list = null;

    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].trim();
      if (!line) { list = null; continue; }

      var bullet = line.match(/^[-*•]\s+(.*)$/);
      if (bullet) {
        if (!list) {
          list = document.createElement('ul');
          list.className = 'raa-list';
          container.appendChild(list);
        }
        var li = document.createElement('li');
        appendInline(li, bullet[1]);
        list.appendChild(li);
        continue;
      }
      list = null;

      // Celý riadok bold (aj s dvojbodkou) alebo ATX heading = nadpis sekcie.
      var head = line.match(/^\*\*([^*]+)\*\*:?$/) || line.match(/^#{1,4}\s+(.*)$/);
      if (head) {
        var h = document.createElement('h4');
        h.className = 'raa-h';
        h.textContent = head[1].trim();
        container.appendChild(h);
        continue;
      }

      var p = document.createElement('p');
      p.className = 'raa-p';
      appendInline(p, line);
      container.appendChild(p);
    }
  }

  // `markdown` = false pre stavy a chyby (tam je Markdown nežiaduci).
  function setOverlayText(text, isError, markdown) {
    var o = buildOverlay();
    while (o.body.firstChild) { o.body.removeChild(o.body.firstChild); }
    if (markdown) {
      renderMarkdownish(o.body, text);
    } else {
      o.body.textContent = text || '';
    }
    o.body.classList.toggle('raa-error', !!isError);
    o.body.classList.toggle('raa-rich', !!markdown);
  }

  function closeOverlay() {
    if (!overlayOpen()) { return; }

    // Zatvorenie počas generovania požiadavku zruší — missclick nemá na čo čakať.
    if (ovAbort) {
      ovAbort.abort();
      ovAbort = null;
    }
    ov.overlay.style.display = 'none';
    // Fokus späť na tlačidlo, z ktorého sa okno otvorilo.
    if (ovOpener && document.contains(ovOpener)) { focusQuietly(ovOpener); }
    ovOpener = null;
  }

  document.addEventListener('click', function (event) {
    var link = event.target.closest('a[data-raa="summary"]');
    if (!link) { return; }
    event.preventDefault();

    var o = buildOverlay();
    ovOpener = link;
    o.title.textContent = (CFG.i18n && CFG.i18n.summaryTitle ? CFG.i18n.summaryTitle : '%{issue}')
      .replace('%{issue}', link.getAttribute('data-issue-label') || '');
    setOverlayText(link.getAttribute('data-working') || '', false, false);
    o.overlay.style.display = 'flex';
    focusQuietly(o.close);

    if (ovAbort) { ovAbort.abort(); }
    ovAbort = window.AbortController ? new window.AbortController() : null;
    var controller = ovAbort;

    post(CFG.summaryPath, { issue_id: link.getAttribute('data-issue-id') },
         controller && controller.signal)
      .then(function (data) {
        if (controller !== ovAbort) { return; } // medzitým zavreté alebo prekliknuté
        setOverlayText(data.text, false, true);
      })
      .catch(function (err) {
        if (err && err.name === 'AbortError') { return; }
        setOverlayText(err.message, true, false);
      })
      .finally(function () {
        if (controller === ovAbort) { ovAbort = null; }
      });
  });

  /* ------------------------------------------------------------------ *
   * Create with AI — predvyplnenie formulára novej úlohy.
   *
   * Formulár sa iba VYPLNÍ. Neodosiela sa nič, „Create" klikne vždy človek.
   * ------------------------------------------------------------------ */

  function draftBox() {
    return document.querySelector('.ai-assistant-draft');
  }

  function fieldValue(id) {
    var el = document.getElementById(id);
    return el ? String(el.value || '') : '';
  }

  /* Tlačidlo má zmysel až keď je z čoho vychádzať — teda je vyplnený názov
   * alebo popis. Beží aj po prekreslení formulára (viď observer nižšie). */
  function syncDraftButton() {
    var box = draftBox();
    if (!box) { return; }
    var btn = box.querySelector('[data-raa="draft"]');
    if (!btn || btn.dataset.raaBusy === '1') { return; }

    var filled = fieldValue('issue_subject').trim() || fieldValue('issue_description').trim();
    btn.disabled = !filled;
  }

  /* Textarea popisu je pri aktívnom Rich Editore skrytá, ale ten si prepísal jej
   * `value` setter tak, že zápis prekreslí aj obsah editora (to isté využíva
   * vkladanie návrhu odpovede vyššie). `re:resync` je jeho explicitný event —
   * posielame ho ako poistku, keby sa setter niekedy zmenil. */
  function setTextField(id, value) {
    var el = document.getElementById(id);
    if (!el || !value) { return; }
    el.value = value;
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('re:resync', { bubbles: true }));
  }

  /* Vracia true, ak sa hodnota naozaj zmenila — podľa toho sa potom rozhodne,
   * či treba nechať Redmine prekresliť formulár.
   *
   * Hodnota sa nastaví LEN ak ju select naozaj obsahuje. Server síce posiela
   * výhradne id z tohto projektu, ale keby sa niekedy rozišli, radšej pole
   * nechať tak, než doňho vpísať neexistujúcu možnosť. */
  function setSelectValue(id, value) {
    var el = document.getElementById(id);
    if (!el || !value) { return false; }

    var wanted = String(value);
    if (el.value === wanted) { return false; }

    var i;
    for (i = 0; i < el.options.length; i++) {
      if (el.options[i].value === wanted) {
        el.value = wanted;
        return true;
      }
    }
    return false;
  }

  function pageHeading() {
    return document.querySelector('#content > h2');
  }

  /* Projekt sa berie z formulára, nie z atribútu na tlačidle. Na formulári je
   * `#issue_project_id` a užívateľ v ňom môže projekt zmeniť (na globálnom
   * /issues/new si ho vyberá rovno) — potom by kategórie, PM aj šablóny prišli
   * z pôvodného projektu. Atribút zostáva ako fallback, keď je pole skryté. */
  function currentProjectId() {
    var select = document.getElementById('issue_project_id');
    if (select && select.value) { return select.value; }

    var box = draftBox();
    return box ? box.getAttribute('data-project-id') : null;
  }

  /* Tlačidlo patrí k nadpisu „New issue". Partial ho renderuje hneď POD nadpis
   * (hook view_issues_new_top), JS ho presunie na ten istý riadok.
   *
   * Presúva sa raz a zdroj je MIMO formulára — prekreslenie #all_attributes po
   * zmene trackera či kategórie ho preto nezduplikuje. */
  function placeDraftButton() {
    var box = draftBox();
    if (!box || box.dataset.raaPlaced === '1') { return; }

    var heading = pageHeading();
    if (!heading) { return; }

    heading.appendChild(box);
    box.dataset.raaPlaced = '1';
  }

  /* Panel s upozorneniami staviame v JS a vkladáme pod nadpis, teda MIMO
   * #all_attributes — zmena trackera či kategórie ten blok prekreslí zo servera
   * a panel by zmizol práve vtedy, keď ho predvyplnenie vyrobilo. Nad formulárom
   * je zároveň hneď vidieť, že AI na niečo upozorňuje.
   *
   * Obsah je od modelu, teda nedôveryhodný vstup → skladá sa z textových nodov,
   * nikdy nie cez innerHTML. */
  function notesPanel() {
    return panelUnderHeading('raa-draft-notes', 'ai-assistant-draft-notes');
  }

  /* Panel sa vkladá POD nadpis stránky, teda MIMO `#all_attributes`: zmena
   * trackera, kategórie alebo nadradenej úlohy prekreslí ten blok zo servera
   * (`$('#all_attributes').empty()` v jadrovom application-legacy.js) a všetko,
   * čo doň plugin vložil, by zmizlo. */
  function panelUnderHeading(id, className) {
    var existing = document.getElementById(id);
    if (existing) { return existing; }

    var panel = document.createElement('div');
    panel.id = id;
    panel.className = className;

    var heading = pageHeading();
    if (heading && heading.parentNode) {
      heading.parentNode.insertBefore(panel, heading.nextSibling);
      return panel;
    }

    var form = document.getElementById('issue-form');
    if (!form) { return null; }

    form.appendChild(panel);
    return panel;
  }

  function appendNoteList(panel, title, items, renderItem) {
    if (!items || !items.length) { return; }

    var heading = document.createElement('p');
    heading.className = 'ai-assistant-draft-heading';
    heading.textContent = title;
    panel.appendChild(heading);

    var list = document.createElement('ul');
    items.forEach(function (item) {
      var li = document.createElement('li');
      renderItem(li, item);
      list.appendChild(li);
    });
    panel.appendChild(list);
  }

  function renderDraftNotes(draft) {
    var panel = notesPanel();
    if (!panel) { return; }

    panel.textContent = '';
    var i18n = CFG.i18n || {};

    // Duplicity sú len upozornenie — nič sa neprepája, rozhoduje človek.
    appendNoteList(panel, i18n.draftSimilar, draft.similar_issues, function (li, item) {
      li.appendChild(issueLink(item));
      if (item.reason) { li.appendChild(document.createTextNode(' — ' + item.reason)); }
    });

    panel.hidden = !panel.firstChild;
  }

  function issueLink(item) {
    var link = document.createElement('a');
    link.href = (CFG.base || '') + '/issues/' + item.id;
    link.target = '_blank';
    link.rel = 'noopener';
    link.textContent = '#' + item.id + ': ' + item.subject;
    return link;
  }

  /* ------------------------------------------------------------------ *
   * Okno „AI issue creator".
   *
   * Tlačidlo formulár NEVYPLŇUJE priamo. Najprv sa v okne ukáže návrh, aby bolo
   * vidieť, čo AI navrhuje — vrátane projektu, ktorý smie zmeniť. Otázky modelu
   * majú vlastné políčka na odpoveď a po „prepočítať" ide celá konverzácia
   * modelu znova (server si žiadny stav nedrží, históriu posiela klient).
   *
   * Obsah je od modelu, teda nedôveryhodný vstup → všetko sa skladá z DOM nodov,
   * nikdy nie cez innerHTML.
   * ------------------------------------------------------------------ */

  var dm = null;                 // referencie na prvky okna, staví sa raz
  var draftState = { history: [], draft: null, abort: null, opener: null };

  function buildDraftModal() {
    if (dm) { return dm; }

    var dlg = buildDialog('raa-dm', (CFG.i18n || {}).draftTitle || 'AI issue creator',
                          closeDraftModal);
    var foot = dlg.foot;
    var recalc = document.createElement('button');
    recalc.type = 'button';
    recalc.id = 'raa-dm-recalc';
    recalc.className = 'ai-assistant-btn';
    recalc.textContent = (CFG.i18n || {}).draftRecalc || '';
    recalc.hidden = true;
    var apply = document.createElement('button');
    apply.type = 'button';
    apply.id = 'raa-dm-apply';
    apply.className = 'ai-assistant-btn raa-dm-primary';
    apply.textContent = (CFG.i18n || {}).draftApply || '';
    apply.disabled = true;
    var cancel = document.createElement('button');
    cancel.type = 'button';
    cancel.id = 'raa-dm-cancel';
    cancel.className = 'ai-assistant-btn';
    cancel.textContent = (CFG.i18n || {}).cancel || 'Cancel';
    foot.appendChild(recalc);
    foot.appendChild(apply);
    foot.appendChild(cancel);

    cancel.addEventListener('click', closeDraftModal);
    apply.addEventListener('click', function () {
      if (draftState.draft) { applyDraft(draftState.draft); }
    });
    recalc.addEventListener('click', function () {
      collectAnswers();
      requestDraft('modal');
    });

    dm = { overlay: dlg.overlay, box: dlg.box, body: dlg.body,
           recalc: recalc, apply: apply, cancel: cancel, close: dlg.close };
    return dm;
  }

  /* Okno sa NEOTVÁRA pri kliknutí. Kým AI pracuje, beží len inline „Pripravujem…"
   * pri tlačidle (rovnako ako pri návrhu odpovede) a okno sa objaví až vtedy, keď
   * má AI otázky. Keď otázky nemá, formulár sa predvyplní priamo a okno sa
   * nezobrazí vôbec. Preto tu žiadny reset histórie nie je — ten patrí kliknutiu. */
  function showDraftModal(opener) {
    var m = buildDraftModal();
    if (opener) { draftState.opener = opener; }
    if (!m.overlay.hidden) { return m; }

    m.overlay.hidden = false;
    focusQuietly(m.close);
    return m;
  }

  function closeDraftModal() {
    if (!dm || dm.overlay.hidden) { return; }
    if (draftState.abort) {
      draftState.abort.abort();
      draftState.abort = null;
    }
    dm.overlay.hidden = true;
    /* `document.contains` je potrebné: opener môže byť medzitým mimo DOM —
     * prekreslenie `#all_attributes` po zmene trackera vymení celý blok. Fokus
     * na odpojený prvok by potichu spadol pod stôl. */
    if (draftState.opener && document.contains(draftState.opener)) {
      focusQuietly(draftState.opener);
    }
  }

  function modalMessage(text, isError) {
    var m = buildDraftModal();
    m.body.textContent = '';
    var p = document.createElement('p');
    p.className = isError ? 'raa-dm-error' : 'raa-dm-status';
    p.textContent = text || '';
    m.body.appendChild(p);
  }

  function addRow(dl, label, value) {
    if (!value) { return; }
    var dt = document.createElement('dt');
    dt.textContent = label;
    var dd = document.createElement('dd');
    dd.textContent = value;
    dl.appendChild(dt);
    dl.appendChild(dd);
  }

  /* Otázky modelu dostanú každá vlastné políčko — to je celý zmysel okna:
   * kým sa nedalo odpovedať, boli otázky slepou uličkou. */
  function renderQuestions(body, questions) {
    var i18n = CFG.i18n || {};
    var heading = document.createElement('p');
    heading.className = 'ai-assistant-draft-heading';
    heading.textContent = i18n.draftQuestions || '';
    body.appendChild(heading);

    questions.forEach(function (question, index) {
      var wrap = document.createElement('div');
      wrap.className = 'raa-dm-question';

      var label = document.createElement('label');
      label.textContent = question;
      label.htmlFor = 'raa-dm-answer-' + index;

      var input = document.createElement('input');
      input.type = 'text';
      input.id = 'raa-dm-answer-' + index;
      input.className = 'raa-dm-answer';
      input.dataset.question = question;
      input.placeholder = i18n.draftAnswer || '';
      // Enter v poli = prepočítať. Bez toho by prehliadač poslal formulár úlohy.
      input.addEventListener('keydown', function (e) {
        if (e.key === 'Enter') {
          e.preventDefault();
          collectAnswers();
          requestDraft('modal');
        }
      });

      wrap.appendChild(label);
      wrap.appendChild(input);
      body.appendChild(wrap);
    });
  }

  function renderDraftProposal(payload) {
    var m = buildDraftModal();
    var i18n = CFG.i18n || {};
    var labels = i18n.labels || {};
    var draft = payload.draft || {};
    var project = payload.project || {};

    draftState.draft = draft;
    m.body.textContent = '';

    if (project.changed) {
      var warn = document.createElement('p');
      warn.className = 'raa-dm-notice';
      warn.textContent = (i18n.draftProjectChanged || '%{project}')
        .replace('%{project}', project.name || '');
      m.body.appendChild(warn);
    }

    var dl = document.createElement('dl');
    dl.className = 'raa-dm-summary';
    addRow(dl, labels.project || 'Project', project.name);
    addRow(dl, labels.subject || 'Subject', draft.subject);
    addRow(dl, labels.tracker || 'Tracker', draft.tracker_name);
    addRow(dl, labels.category || 'Category', draft.category_name);
    addRow(dl, labels.priority || 'Priority', draft.priority_name);
    (draft.custom_field_names || []).forEach(function (row) {
      addRow(dl, row.name, row.value);
    });
    m.body.appendChild(dl);

    /* Poradie je zvolené podľa toho, čo od užívateľa žiada akciu: otázky idú
     * hneď za prehľad. Keď boli až za popisom, ostali pod prehybom okna — teda
     * presne tam, kde si ich nikto nevšimne. Popis je najdlhší a len na
     * prečítanie, takže ide nakoniec. */
    var questions = draft.questions || [];
    if (questions.length) { renderQuestions(m.body, questions); }

    var similar = draft.similar_issues || [];
    if (similar.length) {
      var simHead = document.createElement('p');
      simHead.className = 'ai-assistant-draft-heading';
      simHead.textContent = i18n.draftSimilar || '';
      m.body.appendChild(simHead);
      var ul = document.createElement('ul');
      similar.forEach(function (item) {
        var li = document.createElement('li');
        li.appendChild(issueLink(item));
        if (item.reason) { li.appendChild(document.createTextNode(' — ' + item.reason)); }
        ul.appendChild(li);
      });
      m.body.appendChild(ul);
    }

    if (draft.description) {
      var pre = document.createElement('pre');
      pre.className = 'raa-dm-description';
      pre.textContent = draft.description;
      m.body.appendChild(pre);
    }

    m.recalc.hidden = questions.length === 0;
    m.apply.disabled = false;
  }

  function collectAnswers() {
    if (!dm) { return; }
    var inputs = dm.body.querySelectorAll('.raa-dm-answer');
    Array.prototype.forEach.call(inputs, function (input) {
      if (!input.value.trim()) { return; }
      draftState.history.push({ question: input.dataset.question, answer: input.value.trim() });
    });
  }

  /* `target` určuje, kde sa ukazuje priebeh: 'inline' pri tlačidle (prvé
   * kliknutie), 'modal' v otvorenom okne (prepočítanie s odpoveďami).
   *
   * Rozhodnutie, či sa okno vôbec objaví, padá až po odpovedi servera: keď má AI
   * otázky, otvorí sa okno; keď nie, formulár sa predvyplní priamo. */
  function requestDraft(target) {
    var scope = draftBox();
    var btn = scope ? scope.querySelector('[data-raa="draft"]') : null;
    var i18n = CFG.i18n || {};

    if (draftState.abort) { draftState.abort.abort(); }
    var controller = window.AbortController ? new window.AbortController() : null;
    draftState.abort = controller;
    // Aj na scope, aby krížik pri tlačidle fungoval tým istým handlerom ako
    // pri návrhu odpovede.
    if (scope) { scope._raaAbort = controller; }
    draftState.draft = null;

    if (target === 'modal') {
      var m = buildDraftModal();
      m.apply.disabled = true;
      m.recalc.hidden = true;
      modalMessage(i18n.draftWorking || '', false);
    } else {
      if (btn) { btn.disabled = true; }
      if (scope) {
        setStatus(scope, i18n.draftWorking || '', false);
        toggleCancel(scope, !!controller);
      }
    }

    post(CFG.draftPath, {
      project_id:  currentProjectId(),
      subject:     fieldValue('issue_subject'),
      description: fieldValue('issue_description'),
      history:     draftState.history
    }, controller && controller.signal)
      .then(function (data) {
        // Ochrana pred pretečením starej odpovede po prekliknutí.
        if (controller !== draftState.abort) { return; }

        var draft = data.draft || {};
        draftState.draft = draft;

        if ((draft.questions || []).length) {
          showDraftModal(btn);
          renderDraftProposal(data);
          if (scope) { setStatus(scope, '', false); }
          return;
        }

        // Bez otázok sa okno neotvára — návrh ide priamo do formulára.
        // (`applyDraft` okno zavrie samo, keď náhodou otvorené bolo.)
        applyDraft(draft);
        if (scope) { setStatus(scope, i18n.draftFilled || '', false); }
      })
      .catch(function (err) {
        if (err && err.name === 'AbortError') {
          if (scope) { setStatus(scope, '', false); }
          return;
        }
        if (target === 'modal') {
          modalMessage(err.message, true);
        } else if (scope) {
          setStatus(scope, err.message, true);
        }
      })
      .finally(function () {
        if (btn) { btn.disabled = false; }
        if (scope) { toggleCancel(scope, false); }
        if (controller === draftState.abort) { draftState.abort = null; }
        if (scope && scope._raaAbort === controller) { scope._raaAbort = null; }
      });
  }

  /* Zmena projektu sa NEROBÍ v otvorenom formulári: Redmine by musel prekresliť
   * trackery, kategórie aj custom fieldy a všetko, čo sme medzitým nastavili, by
   * sa rozsypalo. Namiesto toho ideme na formulár nového projektu s hodnotami
   * v URL — to je jadrová cesta (`build_new_issue_from_params`), takže sa cestou
   * uplatnia všetky práva a validácie. */
  function prefillUrl(draft, extra) {
    var q = [];
    function add(key, value) {
      if (value === undefined || value === null || value === '') { return; }
      q.push(encodeURIComponent(key) + '=' + encodeURIComponent(value));
    }
    add('issue[subject]', draft.subject);
    add('issue[description]', draft.description);
    add('issue[tracker_id]', draft.tracker_id);
    add('issue[category_id]', draft.category_id);
    add('issue[priority_id]', draft.priority_id);
    add('issue[assigned_to_id]', draft.assigned_to_id);
    Object.keys(draft.custom_field_values || {}).forEach(function (cfId) {
      add('issue[custom_field_values][' + cfId + ']', draft.custom_field_values[cfId]);
    });
    /* Podúloha potrebuje id NADRADENEJ úlohy, ktoré existuje až po jej založení —
     * preto to nie je súčasť návrhu, ale doplní ho fronta až v ďalšom kroku.
     * `back_url` posiela jadro späť na stránku nadradenej úlohy; keď je v URL
     * zároveň `parent_issue_id`, Redmine navyše vykreslí „Create and follow"
     * (jadrové new.html.erb). */
    add('issue[parent_issue_id]', extra && extra.parentIssueId);
    add('back_url', extra && extra.backUrl);

    return (CFG.base || '') + '/projects/' + draft.project_id + '/issues/new?' + q.join('&');
  }

  /* Poradie je podstatné: najprv polia, ktoré formulár neprekresľujú, a až
   * NAKONIEC tracker/kategória. Tie majú v Redmine onchange, ktorý pošle celý
   * formulár na server a prekreslí #all_attributes — vďaka tomuto poradiu sa
   * všetko ostatné odošle s ním a po prekreslení tam zostane. */
  function applyDraft(draft) {
    if (draft.project_id && String(draft.project_id) !== String(currentProjectId())) {
      window.location.assign(prefillUrl(draft));
      return;
    }

    setTextField('issue_subject', draft.subject);
    setTextField('issue_description', draft.description);

    setSelectValue('issue_priority_id', draft.priority_id);
    setSelectValue('issue_assigned_to_id', draft.assigned_to_id);

    Object.keys(draft.custom_field_values || {}).forEach(function (cfId) {
      var value = draft.custom_field_values[cfId];
      // Povinné polia (v Previu „Project Manager") bývajú select, ale môžu byť
      // aj text — skúsime oboje, poradie je bezpečné.
      if (!setSelectValue('issue_custom_field_values_' + cfId, value)) {
        var el = document.getElementById('issue_custom_field_values_' + cfId);
        if (el && el.tagName !== 'SELECT') {
          el.value = value;
          el.dispatchEvent(new Event('input', { bubbles: true }));
        }
      }
    });

    // Upozornenie na duplicity necháme aj na stránke — po zavretí okna nezmizne.
    renderDraftNotes(draft);
    closeDraftModal();

    var trackerChanged = setSelectValue('issue_tracker_id', draft.tracker_id);
    var categoryChanged = setSelectValue('issue_category_id', draft.category_id);

    // Jeden refresh stačí — prenesie so sebou aj druhú zmenu.
    var trigger = trackerChanged ? 'issue_tracker_id'
                                 : (categoryChanged ? 'issue_category_id' : null);
    if (trigger) {
      document.getElementById(trigger)
              .dispatchEvent(new Event('change', { bubbles: true }));
    }
  }

  document.addEventListener('click', function (event) {
    var btn = event.target.closest('.ai-assistant-btn[data-raa="draft"]');
    if (!btn) { return; }
    event.preventDefault();

    // Nové kliknutie = nová konverzácia, takže staré odpovede sa zahodia.
    draftState.history = [];
    draftState.opener = btn;
    requestDraft('inline');
  });

  /* ===========================================================================
   * Režim plánu — okno „AI issue creator" z prútika v hlavičke.
   *
   * Rozdiel proti Fáze 1: sem sa vchádza BEZ formulára a bez projektu, takže
   * okno musí najprv ponúknuť, kam sa zakladá, a text zadania si vyžiadať samo.
   * Odpoveďou nie je jedna úloha, ale plán — jedna alebo viac úloh, prípadne
   * nadradená úloha s podúlohami.
   * ========================================================================= */

  var pl = null;
  var planState = {
    // Celý transkript konverzácie. Server je bezstavový, históriu posiela klient.
    messages: [],
    plan: null,
    projects: null,   // z plan_context, cache na životnosť stránky
    // Prvá RUČNÁ zmena projektu ho zamkne: dovtedy smie projekt zmeniť AI
    // podľa obsahu zadania, potom už nie.
    lockProject: false,
    abort: null,
    opener: null
  };

  var PLAN_PROJECT_KEY = 'raa.plan.project';

  function planText(key, fallback) {
    var t = (CFG.i18n || {}).plan || {};
    return t[key] || fallback || '';
  }

  function buildPlanDialog() {
    if (pl) { return pl; }

    var dlg = buildDialog('raa-pl', planText('title', 'AI issue creator'), closePlanDialog);

    // Telo: transkript konverzácie a pod ním posledný návrh plánu.
    var log = document.createElement('div');
    log.id = 'raa-pl-log';
    var plan = document.createElement('div');
    plan.id = 'raa-pl-plan';
    dlg.body.appendChild(log);
    dlg.body.appendChild(plan);

    /* Composer je MIMO tela: telo sa scrolluje a prekresľuje, vstupné pole má
     * zostať na mieste a nemá sa pri prekreslení plánu stratiť rozpísaný text. */
    var composer = document.createElement('div');
    composer.id = 'raa-pl-composer';

    var label = document.createElement('label');
    label.id = 'raa-pl-input-label';
    label.setAttribute('for', 'raa-pl-input');
    label.textContent = planText('inputLabel');

    var input = document.createElement('textarea');
    input.id = 'raa-pl-input';
    input.rows = 3;
    input.placeholder = planText('placeholder');

    var row = document.createElement('div');
    row.id = 'raa-pl-row';
    var projectLabel = document.createElement('label');
    projectLabel.setAttribute('for', 'raa-pl-project');
    projectLabel.textContent = ((CFG.i18n || {}).labels || {}).project || 'Project';
    var project = document.createElement('select');
    project.id = 'raa-pl-project';
    var lockWrap = document.createElement('label');
    lockWrap.id = 'raa-pl-lock-label';
    var lock = document.createElement('input');
    lock.type = 'checkbox';
    lock.id = 'raa-pl-lock';
    lockWrap.appendChild(lock);
    lockWrap.appendChild(document.createTextNode(' ' + planText('projectLock')));
    row.appendChild(projectLabel);
    row.appendChild(project);
    row.appendChild(lockWrap);

    /* Prečo AI vybrala tento projekt. Bez toho je zmena projektu neprehľadná —
     * človek nevie, či sa model rozhodol podľa obsahu, alebo náhodou. */
    var projectReason = document.createElement('p');
    projectReason.id = 'raa-pl-project-reason';
    projectReason.hidden = true;

    composer.appendChild(label);
    composer.appendChild(input);
    /* Projekt sa pri prvom zadaní NEVYBERÁ — určuje ho AI podľa obsahu. Riadok sa
     * odkryje až s návrhom, aby sa dal projekt ručne opraviť. Vyberať ho dopredu
     * znamenalo hádať a zároveň to model odkláňalo: kontext projektu bral ako
     * pokyn, kam úlohu napasovať. */
    row.hidden = true;
    composer.appendChild(row);
    composer.appendChild(projectReason);
    dlg.box.insertBefore(composer, dlg.foot);

    // Päta: Cancel vľavo, primárna akcia vpravo.
    var cancel = document.createElement('button');
    cancel.type = 'button';
    cancel.id = 'raa-pl-cancel';
    cancel.className = 'ai-assistant-btn';
    cancel.textContent = (CFG.i18n || {}).cancel || 'Cancel';
    var submit = document.createElement('button');
    submit.type = 'button';
    submit.id = 'raa-pl-submit';
    submit.className = 'ai-assistant-btn raa-dm-primary';
    submit.textContent = planText('submit');
    submit.disabled = true;
    var accept = document.createElement('button');
    accept.type = 'button';
    accept.id = 'raa-pl-accept';
    accept.className = 'ai-assistant-btn raa-dm-primary';
    accept.textContent = planText('accept');
    accept.hidden = true;
    dlg.foot.appendChild(cancel);
    dlg.foot.appendChild(submit);
    dlg.foot.appendChild(accept);

    cancel.addEventListener('click', closePlanDialog);
    submit.addEventListener('click', submitPlanAnswers);
    accept.addEventListener('click', function () {
      if (planState.plan) { acceptPlan(planState.plan); }
    });
    input.addEventListener('input', syncPlanSubmit);
    /* Ctrl+Enter odosiela, samotný Enter robí nový riadok: do textarey sa píše
     * viac viet a Enter ako odoslanie by text rozsekal. */
    input.addEventListener('keydown', function (e) {
      if (e.key === 'Enter' && (e.ctrlKey || e.metaKey) && !submit.disabled) {
        e.preventDefault();
        submit.click();
      }
    });
    project.addEventListener('change', function () {
      // Ručná zmena projektu je pokyn: AI ho už prepisovať nesmie.
      planState.lockProject = true;
      lock.checked = true;
      try { window.localStorage.setItem(PLAN_PROJECT_KEY, project.value); } catch (e) {}
    });
    lock.addEventListener('change', function () {
      planState.lockProject = lock.checked;
    });

    pl = { overlay: dlg.overlay, box: dlg.box, body: dlg.body, foot: dlg.foot,
           log: log, plan: plan, composer: composer, input: input, row: row,
           project: project, projectReason: projectReason, lock: lock,
           submit: submit, accept: accept, cancel: cancel, close: dlg.close };
    return pl;
  }

  function syncPlanSubmit() {
    if (!pl) { return; }
    /* Odpoveď na otázku je plnohodnotný vstup: keby sa tlačidlo riadilo len
     * composerom, po prvom kole by zostalo zakázané (pole sa po odoslaní
     * vyprázdni) a na otázky by sa nedalo odpovedať vôbec. */
    var answered = Array.prototype.some.call(
      pl.plan.querySelectorAll(".raa-pl-answer"),
      function (i) { return i.value.trim().length > 0; }
    );
    pl.submit.disabled = pl.input.value.trim().length === 0 && !answered;
  }

  function closePlanDialog() {
    if (!pl || pl.overlay.hidden) { return; }

    // Zatvorenie počas generovania požiadavku zruší — missclick nemá na čo čakať.
    if (planState.abort) {
      planState.abort.abort();
      planState.abort = null;
    }
    pl.overlay.hidden = true;
    // Opener je odkaz v hlavičke; po prekreslení stránky už nemusí byť v DOM.
    if (planState.opener && document.contains(planState.opener)) {
      focusQuietly(planState.opener);
    }
  }

  /* Zoznam projektov sa dotiahne pri prvom otvorení a drží sa do konca stránky.
   * Nie je v `RAA_CONFIG` zámerne: ten sa vykresľuje v layoute na každej
   * stránke a nesmie robiť SQL dotazy. */
  function loadPlanProjects() {
    if (planState.projects) {
      fillPlanProjects();
      return;
    }
    post(CFG.planContextPath, { project_id: CFG.projectId })
      .then(function (data) {
        planState.projects = (data && data.projects) || [];
        fillPlanProjects();
      })
      .catch(function () {
        // Bez zoznamu projektov sa plán zadať nedá — povedz to a nechaj okno.
        planMessage(planText('noResult'), true);
      });
  }

  function fillPlanProjects() {
    var sel = pl.project;
    /* Options sa plnia LEN RAZ. Pri druhom otvorení okna sa výber nesmie
     * prepočítať — človek ho mohol ručne zmeniť a taká zmena je pokyn, nie
     * dočasný stav. */
    if (sel.options.length) { return; }
    sel.textContent = '';
    (planState.projects || []).forEach(function (p) {
      var opt = document.createElement('option');
      opt.value = String(p.id);
      opt.textContent = p.name;
      // Príznak nesieme na elemente, aby okno vedelo o práve na podúlohy
      // bez ďalšieho dotazu pri zmene projektu.
      opt.dataset.subtasks = p.subtasks ? '1' : '0';
      sel.appendChild(opt);
    });
    // Poradie preferencií: projekt stránky → naposledy použitý → prvý v zozname.
    var stored = null;
    try { stored = window.localStorage.getItem(PLAN_PROJECT_KEY); } catch (e) {}
    var wanted = [CFG.projectId, stored].filter(Boolean).map(String);
    for (var i = 0; i < wanted.length; i++) {
      if (sel.querySelector('option[value="' + wanted[i] + '"]')) {
        sel.value = wanted[i];
        return;
      }
    }
  }

  function planMessage(text, isError) {
    var m = buildPlanDialog();
    m.plan.textContent = '';
    var p = document.createElement('p');
    p.className = isError ? 'raa-dm-error' : 'raa-dm-status';
    p.textContent = text || '';
    m.plan.appendChild(p);
  }

  function openPlanDialog(opener) {
    var m = buildPlanDialog();
    planState.opener = opener || null;
    if (m.overlay.hidden) { m.overlay.hidden = false; }
    loadPlanProjects();
    syncPlanSubmit();
    focusQuietly(m.input);
    return m;
  }

  /* Jedno kolo konverzácie. Celý transkript sa posiela znova — server je
   * bezstavový a históriu drží klient. */
  /* Jadro Redmine sleduje VŠETKY `<textarea>` na stránke (`warnLeavingUnsaved`
   * v application-legacy.js) a tú našu si pri písaní označí ako zmenenú. Pri
   * navigácii potom prehliadač vypíše „Leave site?", hoci sa žiadny formulár
   * nerozpísal. Príznak preto po odoslaní z NAŠEJ textarey zmažeme — cudzie
   * textarey (rozpísaný popis úlohy) sa nedotýkame, tam varovanie patrí. */
  function clearUnsavedFlag() {
    try {
      if (window.jQuery && pl) { window.jQuery(pl.input).removeData('changed'); }
    } catch (e) {}
  }

  function requestPlan() {
    var m = buildPlanDialog();
    var text = m.input.value.trim();
    if (!text) { return; }

    if (planState.abort) { planState.abort.abort(); }
    var controller = window.AbortController ? new window.AbortController() : null;
    planState.abort = controller;
    planState.plan = null;

    // Zadanie ide do transkriptu HNEĎ a pole sa vyprázdni: keby sme čakali na
      // odpoveď, človek by nevidel, že sa jeho text odoslal, a písal by znova.
    planState.messages.push({ role: 'user', text: text });
    m.input.value = '';
    clearUnsavedFlag();
    syncPlanSubmit();
    renderPlanLog();

    m.submit.disabled = true;
    m.accept.hidden = true;
    planMessage(planText('working'), false);

    /* `project_id` sa posiela len keď si ho človek zamkol. Inak ho vyberá server
     * samostatným volaním podľa obsahu zadania. */
    post(CFG.planPath, {
      project_id: planState.lockProject ? m.project.value : null,
      input: planInputForServer(),
      messages: planState.messages,
      lock_project: planState.lockProject ? '1' : '0'
    }, controller && controller.signal)
      .then(function (data) {
        // Ochrana pred pretečením starej odpovede po prekliknutí.
        if (controller !== planState.abort) { return; }

        var plan = (data && data.plan) || {};
        planState.plan = plan;
        if (!(plan.issues || []).length) {
          planMessage(planText('noResult'), true);
          return;
        }
        // Model má v ďalšom kole vidieť, čo sám navrhol, aby na tom stavěl
        // a neopakoval sa.
        planState.messages.push({ role: 'ai', text: planAiRecap(plan) });
        renderPlanLog();
        renderPlan(data);
      })
      .catch(function (err) {
        if (err && err.name === 'AbortError') { return; }
        planMessage(err.message, true);
      })
      .finally(function () {
        if (controller === planState.abort) { planState.abort = null; }
        syncPlanSubmit();
        // Ďalšie kolo je doplnenie, nie nové zadanie.
        if (planState.messages.length > 1) { m.submit.textContent = planText('refine'); }
      });
  }

  /* Serveru ide PRVÉ zadanie ako `input`; ďalšie kolá sú v `messages`. Držíme
   * to oddelene, aby prompt mal jasné „zadání" a pod ním konverzáciu — inak by
   * model nevedel, čo je pôvodná požiadavka a čo neskoršie doplnenie. */
  function planInputForServer() {
    for (var i = 0; i < planState.messages.length; i++) {
      if (planState.messages[i].role === 'user') { return planState.messages[i].text; }
    }
    return '';
  }

  /* Krátky odtlačok plánu do transkriptu. Nie celé popisy — to by v ďalšom
   * kole zaplatilo tie isté tokeny druhý raz. */
  function planAiRecap(plan) {
    var lines = [plan.summary || ''];
    (plan.issues || []).forEach(function (it, n) {
      var mark = plan.use_parent ? (n === 0 ? '[parent]' : '[podúkol]') : '[úkol]';
      lines.push(mark + ' ' + (it.subject || ''));
    });
    (plan.questions || []).forEach(function (q) { lines.push('[otázka] ' + q); });
    return lines.filter(Boolean).join('\n');
  }

  /* Transkript zobrazuje LEN to, čo napísal človek.
   *
   * Odtlačok plánu (`planAiRecap`) sa do `messages` pridáva kvôli modelu — aby
   * v ďalšom kole vedel, čo už navrhol — ale vypisovať ho je zbytočné: ten istý
   * obsah je hneď pod transkriptom vykreslený ako plán, a v surovej podobe
   * (`[parent] …`, neprelozený Markdown) je to len šum. */
  function renderPlanLog() {
    var m = buildPlanDialog();
    m.log.textContent = '';
    planState.messages.forEach(function (msg) {
      if (msg.role !== 'user') { return; }

      var turn = document.createElement('div');
      turn.className = 'raa-pl-turn raa-pl-user';
      // textContent, nie innerHTML — je to vstup, ktorý sa vracia zo servera.
      turn.textContent = msg.text;
      m.log.appendChild(turn);
    });
  }

  /* Vykreslenie plánu. Všetko z modelu ide cez textContent alebo cez
   * `renderMarkdownish` (ktorý skladá DOM nody) — nikdy innerHTML. */
  function renderPlan(data) {
    var m = buildPlanDialog();
    var plan = data.plan || {};
    var i18n = CFG.i18n || {};
    m.plan.textContent = '';

    if (data.project && data.project.changed) {
      var notice = document.createElement('p');
      notice.className = 'raa-dm-notice';
      notice.textContent = (i18n.draftProjectChanged || '%{project}')
        .replace('%{project}', data.project.name || '');
      m.plan.appendChild(notice);
      // Select dorovnáme, aby ďalšie kolo šlo do toho istého projektu.
      if (m.project.querySelector('option[value="' + data.project.id + '"]')) {
        m.project.value = String(data.project.id);
      }
    }

    /* Poznámka o chýbajúcom práve je dôležitejšia než samotný plán: bez nej by
     * človek nechápal, prečo sú úlohy samostatné, a hľadal by chybu. */
    if (plan.subtasks_allowed === false) {
      var perm = document.createElement('p');
      perm.className = 'raa-dm-notice';
      perm.textContent = (planText('noSubtasks') || '')
        .replace('%{project}', (data.project && data.project.name) || '');
      m.plan.appendChild(perm);
    }

    var heading = document.createElement('p');
    heading.className = 'ai-assistant-draft-heading';
    heading.textContent = planText('heading');
    m.plan.appendChild(heading);

    if (plan.summary) {
      var sum = document.createElement('div');
      sum.className = 'raa-pl-summary raa-rich';
      renderMarkdownish(sum, plan.summary);
      m.plan.appendChild(sum);
    }

    (plan.issues || []).forEach(function (item, index) {
      m.plan.appendChild(planCard(item, index, plan));
    });

    if ((plan.questions || []).length) { renderPlanQuestions(m.plan, plan.questions); }
    syncPlanSubmit();

    if ((plan.similar_issues || []).length) {
      var simHead = document.createElement('p');
      simHead.className = 'ai-assistant-draft-heading';
      simHead.textContent = i18n.draftSimilar || '';
      m.plan.appendChild(simHead);
      var ul = document.createElement('ul');
      ul.className = 'raa-list';
      plan.similar_issues.forEach(function (it) {
        var li = document.createElement('li');
        li.appendChild(issueLink(it));
        if (it.reason) { li.appendChild(document.createTextNode(' — ' + it.reason)); }
        ul.appendChild(li);
      });
      m.plan.appendChild(ul);
    }

    m.accept.hidden = false;
    /* Od návrhu ďalej je hlavný obsah okna plán, nie písanie: vstupné pole sa
     * zmenší na jeden riadok a telo dostane miesto. Riadok s projektom sa odkryje
     * na ručnú opravu. */
    m.composer.classList.add('raa-pl-compact');
    m.input.rows = 1;
    m.row.hidden = false;
    if (data.project && m.project.querySelector('option[value="' + data.project.id + '"]')) {
      m.project.value = String(data.project.id);
    }
    if (data.project && data.project.reason) {
      m.projectReason.textContent = data.project.reason;
      m.projectReason.hidden = false;
    }
  }

  function planCard(item, index, plan) {
    var i18n = CFG.i18n || {};
    var labels = i18n.labels || {};
    var card = document.createElement('div');
    card.className = 'raa-pl-card';

    var role;
    if (!plan.use_parent) { role = 'standalone'; }
    else if (index === 0) { role = 'parent'; }
    else { role = 'subtask'; }
    card.dataset.role = role;

    var badge = document.createElement('span');
    badge.className = 'raa-pl-badge';
    badge.textContent = planText(role) + (role === 'parent' ? '' :
      ' ' + (role === 'subtask' ? index : index + 1) + '/' +
      (role === 'subtask' ? (plan.issues.length - 1) : plan.issues.length));
    card.appendChild(badge);

    var h = document.createElement('h4');
    h.className = 'raa-pl-subject';
    h.textContent = item.subject || '';
    card.appendChild(h);

    var dl = document.createElement('dl');
    dl.className = 'raa-dm-summary';
    addRow(dl, labels.tracker || 'Tracker', item.tracker_name);
    addRow(dl, labels.category || 'Category', item.category_name);
    addRow(dl, labels.priority || 'Priority', item.priority_name);
    (item.custom_field_names || []).forEach(function (cf) { addRow(dl, cf.name, cf.value); });
    if (dl.children.length) { card.appendChild(dl); }

    if (item.description) {
      var pre = document.createElement('pre');
      pre.className = 'raa-dm-description';
      pre.textContent = item.description;
      card.appendChild(pre);
    }
    return card;
  }

  /* Otázky plánu. Odpoveď sa nezapisuje ako pár otázka/odpoveď (to je formát
   * Fázy 1), ale ako ďalší vstup do transkriptu — server tu má jediný formát. */
  function renderPlanQuestions(container, questions) {
    var i18n = CFG.i18n || {};
    var heading = document.createElement('p');
    heading.className = 'ai-assistant-draft-heading';
    heading.textContent = i18n.draftQuestions || '';
    container.appendChild(heading);

    questions.forEach(function (question, index) {
      var wrap = document.createElement('div');
      wrap.className = 'raa-dm-question';
      var label = document.createElement('label');
      label.textContent = question;
      label.htmlFor = 'raa-pl-answer-' + index;
      var input = document.createElement('input');
      input.type = 'text';
      input.id = 'raa-pl-answer-' + index;
      input.className = 'raa-pl-answer';
      input.dataset.question = question;
      input.placeholder = i18n.draftAnswer || '';
      input.addEventListener('input', syncPlanSubmit);
      input.addEventListener('keydown', function (e) {
        if (e.key === 'Enter') {
          e.preventDefault();
          submitPlanAnswers();
        }
      });
      wrap.appendChild(label);
      wrap.appendChild(input);
      container.appendChild(wrap);
    });
  }

  /* Odpovede na otázky sa zlejú do jedného vstupu spolu s prípadným textom
   * v composeri — je to jedno kolo konverzácie, nie dve. */
  function submitPlanAnswers() {
    var m = buildPlanDialog();
    var parts = [];
    Array.prototype.forEach.call(m.plan.querySelectorAll('.raa-pl-answer'), function (input) {
      var value = input.value.trim();
      if (value) { parts.push(input.dataset.question + ' → ' + value); }
    });
    var typed = m.input.value.trim();
    if (typed) { parts.push(typed); }
    if (!parts.length) { return; }

    m.input.value = parts.join('\n');
    syncPlanSubmit();
    requestPlan();
  }

  /* ===========================================================================
   * Sprievodca zakladaním — fronta úloh z prijatého plánu.
   *
   * Poradie je vynútené jadrom Redmine: `issue[parent_issue_id]` musí ukazovať na
   * EXISTUJÚCU viditeľnú úlohu, inak Create padne na validácii. Číslo nadradenej
   * úlohy teda vznikne až tým, že ju človek uloží — a až potom sa dajú
   * predvyplniť podúlohy. Otvoriť všetky formuláre naraz preto nejde.
   *
   * Nič sa neukladá na server: fronta je v `sessionStorage` a každú úlohu ukladá
   * jadrový IssuesController#create po kliknutí človeka.
   * ========================================================================= */

  var QUEUE_KEY = 'raa.plan.queue';
  /* Dve hodiny. Nedokončený plán je vec TEJTO karty (preto sessionStorage a nie
   * localStorage) — a aj v nej má po čase zmiznúť, aby sa panel neobjavil pri
   * úlohe, ktorú človek zakladá o tri hodiny neskôr a s plánom nesúvisí. */
  var QUEUE_TTL = 2 * 60 * 60 * 1000;
  var QUEUE_VERSION = 1;

  function queueStore() {
    try { return window.sessionStorage; } catch (e) { return null; }
  }

  function dropQueue() {
    var s = queueStore();
    if (s) { try { s.removeItem(QUEUE_KEY); } catch (e) {} }
    return null;
  }

  /* `sessionStorage` je zapisovateľné z konzoly prehliadača, a my z fronty
   * skladáme URL a vkladáme z nej text do DOM. Preto sa pri čítaní všetko
   * pretláča cez sanitáciu: id-ká musia byť čísla, texty sa krátia, a URL vždy
   * skladá `prefillUrl` — nikdy sa neberie hotová z úložiska. */
  function intOrNull(v) {
    return /^[0-9]{1,9}$/.test(String(v)) ? String(v) : null;
  }

  function safeText(v, max) {
    return v === undefined || v === null ? null : String(v).slice(0, max);
  }

  function sanitizeItem(raw) {
    if (!raw || typeof raw !== 'object') { return null; }
    var subject = safeText(raw.subject, 255);
    var projectId = intOrNull(raw.project_id);
    if (!subject || !projectId) { return null; }

    var cfv = {};
    var src = raw.custom_field_values && typeof raw.custom_field_values === 'object'
      ? raw.custom_field_values : {};
    Object.keys(src).forEach(function (k) {
      if (intOrNull(k)) { cfv[k] = safeText(src[k], 255); }
    });

    return { subject: subject,
             description: safeText(raw.description, 20000),
             tracker_id: intOrNull(raw.tracker_id),
             category_id: intOrNull(raw.category_id),
             priority_id: intOrNull(raw.priority_id),
             assigned_to_id: intOrNull(raw.assigned_to_id),
             custom_field_values: cfv,
             project_id: projectId,
             state: raw.state === 'created' || raw.state === 'skipped' ? raw.state : 'pending' };
  }

  function readQueue() {
    var s = queueStore();
    if (!s) { return null; }

    var raw;
    try { raw = JSON.parse(s.getItem(QUEUE_KEY)); } catch (e) { return dropQueue(); }
    if (!raw || raw.v !== QUEUE_VERSION || !Array.isArray(raw.items) || !raw.items.length) {
      return raw ? dropQueue() : null;
    }
    if (!(typeof raw.created === 'number' && Date.now() - raw.created < QUEUE_TTL)) {
      return dropQueue();
    }

    var items = raw.items.map(sanitizeItem);
    if (items.some(function (i) { return i === null; })) { return dropQueue(); }

    var cursor = parseInt(raw.cursor, 10);
    if (!(cursor >= 0 && cursor <= items.length)) { return dropQueue(); }

    return { v: QUEUE_VERSION, created: raw.created, items: items, cursor: cursor,
             useParent: raw.useParent === true,
             parentIssueId: intOrNull(raw.parentIssueId),
             awaiting: parseInt(raw.awaiting, 10) >= 0 ? parseInt(raw.awaiting, 10) : null,
             submitted: raw.submitted === true };
  }

  function writeQueue(q) {
    var s = queueStore();
    if (!s) { return; }
    try { s.setItem(QUEUE_KEY, JSON.stringify(q)); } catch (e) {}
  }

  /* Prijatie plánu. Formulár sa NEOTVÁRA na pozadí a nič sa neukladá — len sa
   * postaví fronta a prejde na predvyplnený formulár prvej úlohy. */
  function acceptPlan(plan) {
    var items = (plan.issues || []).map(function (it) {
      return { subject: it.subject, description: it.description,
               tracker_id: it.tracker_id, category_id: it.category_id,
               priority_id: it.priority_id, assigned_to_id: it.assigned_to_id,
               custom_field_values: it.custom_field_values || {},
               project_id: it.project_id, state: 'pending' };
    });
    if (!items.length) { return; }

    var q = { v: QUEUE_VERSION, created: Date.now(), items: items, cursor: 0,
              useParent: plan.use_parent === true, parentIssueId: null, awaiting: 0,
              submitted: false };

    /* Jedna úloha nie je čo sprevádzať: fronta by po založení ukázala panel
     * „1 z 1 založené" a tlačidlo na zrušenie plánu, ktorý už neexistuje.
     * Navigujeme priamo na formulár a nič si nepamätáme. */
    if (items.length === 1) {
      dropQueue();
      clearUnsavedFlag();
      closePlanDialog();
      window.location.assign(prefillUrl(items[0]));
      return;
    }

    writeQueue(q);
    clearUnsavedFlag();
    closePlanDialog();
    window.location.assign(queueUrlFor(q, 0));
  }

  /* URL na predvyplnenie k-tej úlohy. Nadradená úloha ide BEZ `back_url`: jej id
   * čítame z adresy `/issues/<id>`, na ktorú nás jadro po Create pošle. Podúlohy
   * `back_url` naopak majú, aby sa človek vracal tam, kde vidí, čo už stojí. */
  function queueUrlFor(q, index) {
    var item = q.items[index];
    var isParent = q.useParent && index === 0;
    if (isParent || !q.parentIssueId) { return prefillUrl(item); }

    return prefillUrl(item, { parentIssueId: q.parentIssueId,
                              backUrl: (CFG.base || '') + '/issues/' + q.parentIssueId });
  }

  function nextPending(q) {
    for (var i = q.cursor; i < q.items.length; i++) {
      if (q.items[i].state === 'pending') { return i; }
    }
    return -1;
  }

  function queueDone(q) {
    return q.items.filter(function (i) { return i.state === 'created'; }).length;
  }

  /* Id úlohy zo adresy `/issues/123`. Vracia null aj na `/issues/123/edit`,
   * `/issues` a podobne — panel má reagovať len na detail úlohy. */
  function issueIdFromPath() {
    var m = String(window.location.pathname).match(/\/issues\/(\d+)\/?$/);
    return m ? m[1] : null;
  }

  /* Panel fronty. Beží pri každom načítaní stránky a sám sa rozhodne, či má
   * čo zobraziť. */
  function initPlanQueue() {
    var q = readQueue();
    if (!q) { return; }

    var issueId = issueIdFromPath();
    /* Že sa úloha naozaj založila, poznáme z DVOCH vecí: navigovali sme na jej
     * formulár (`awaiting`) a ten formulár sa aj odoslal (`submitted`). Na
     * `document.referrer` sa to postaviť NEDÁ: Referrer-Policy ho môže skrátiť
     * na origin a potom by sa fronta nikdy nepohnula.
     *
     * Bez druhej podmienky stačilo z formulára odbočiť na hocijakú existujúcu
     * úlohu a fronta ju započítala ako založenú — jej číslo sa stalo nadradenou
     * úlohou a podúlohy sa naviazali na cudziu vec. */
    if (issueId && q.submitted && q.awaiting !== null && q.items[q.awaiting]) {
      q.items[q.awaiting].state = 'created';
      if (q.awaiting === 0 && q.useParent) { q.parentIssueId = issueId; }
      q.cursor = q.awaiting + 1;
      q.awaiting = null;
      q.submitted = false;
      writeQueue(q);
    } else if (!issueId && q.submitted) {
      /* Odoslalo sa, ale neskončili sme na úlohe — formulár vrátila validácia.
       * Príznak zhasíname, aby neplatil až pre ďalšie, nesúvisiace prekliknutie. */
      q.submitted = false;
      writeQueue(q);
    }

    var onNewIssue = !!document.getElementById('issue-form') && !issueId;
    var onBase = !!issueId;
    if (!onNewIssue && !onBase) { return; }

    if (onNewIssue) { armQueueSubmit(); }
    renderQueuePanel(q, onNewIssue);
  }

  /* Príznak „formulár sa odoslal" sa stavia až na `submit`, teda na kliknutí
   * Create — nie na tom, že sme na nejakej adrese. Platí to pre všetky tri
   * jadrové tlačidlá (Create, Create and continue, Create and follow), lebo
   * odosielajú ten istý formulár. Zápis do `sessionStorage` je synchrónny,
   * takže sa stihne pred odchodom zo stránky. */
  function armQueueSubmit() {
    var form = document.getElementById('issue-form');
    if (!form || form.dataset.raaArmed === '1') { return; }
    form.dataset.raaArmed = '1';
    form.addEventListener('submit', function () {
      var fresh = readQueue();
      if (!fresh) { return; }
      fresh.submitted = true;
      writeQueue(fresh);
    });
  }

  function renderQueuePanel(q, onNewIssue) {
    var panel = panelUnderHeading('raa-plan-queue', 'ai-assistant-draft-notes raa-plan-queue');
    if (!panel) { return; }
    panel.textContent = '';

    var next = nextPending(q);
    var line = document.createElement('p');
    line.className = 'raa-plan-queue-line';
    line.textContent = planText('queueProgress')
      .replace('%{done}', String(queueDone(q)))
      .replace('%{total}', String(q.items.length));
    panel.appendChild(line);

    /* Nadradená úloha preskočená: ostatné úlohy vzniknú samostatne. Povedať to
     * treba nahlas — inak by človek čakal hierarchiu, ktorá nevznikne. */
    if (q.useParent && !q.parentIssueId && q.cursor > 0) {
      var warn = document.createElement('p');
      warn.className = 'raa-dm-notice';
      warn.textContent = planText('queueNoParent');
      panel.appendChild(warn);
    }

    /* Pole „nadradená úloha" vo formulári nie je, hoci sme ho do URL dali — to je
     * ten tichý zahod pri chýbajúcom práve :manage_subtasks. */
    if (onNewIssue && q.parentIssueId && !document.getElementById('issue_parent_issue_id')) {
      var miss = document.createElement('p');
      miss.className = 'raa-dm-notice';
      miss.textContent = planText('queueParentMissing');
      panel.appendChild(miss);
    }

    if (next >= 0) {
      var nextLine = document.createElement('p');
      nextLine.className = 'raa-plan-queue-next';
      nextLine.textContent = planText('queueNext').replace('%{subject}', q.items[next].subject);
      panel.appendChild(nextLine);
    } else {
      var done = document.createElement('p');
      done.className = 'raa-plan-queue-next';
      done.textContent = planText('queueDone');
      panel.appendChild(done);
    }

    var actions = document.createElement('p');
    actions.className = 'raa-plan-queue-actions';

    /* Na formulári sa nenaviguje — už na ňom stojíme.
     *
     * Je to `<a href>`, nie `<button>`: ide o navigáciu na predvyplnený formulár,
     * takže odkaz je semanticky správny a navyše zadarmo dáva Ctrl+klik do nového
     * panelu, stredné tlačidlo aj „kopírovať adresu". Poznačenie do fronty ide
     * v handleri PRED navigáciou a `preventDefault` sa nevolá — prehliadač
     * naviguje sám. */
    if (next >= 0 && !onNewIssue) {
      var go = document.createElement('a');
      go.className = 'ai-assistant-btn raa-dm-primary';
      go.id = 'raa-plan-queue-go';
      go.textContent = planText('queueGo');
      go.href = queueUrlFor(q, next);
      go.addEventListener('click', function () {
        var fresh = readQueue();
        if (!fresh) { return; }
        var idx = nextPending(fresh);
        if (idx < 0) { return; }
        fresh.awaiting = idx;
        fresh.cursor = idx;
        writeQueue(fresh);
      });
      actions.appendChild(go);
    }

    if (next >= 0) {
      var skip = document.createElement('button');
      skip.type = 'button';
      skip.className = 'ai-assistant-btn';
      skip.id = 'raa-plan-queue-skip';
      skip.textContent = planText('queueSkip');
      skip.addEventListener('click', function () {
        var fresh = readQueue();
        if (!fresh) { return; }
        var idx = nextPending(fresh);
        if (idx < 0) { return; }
        fresh.items[idx].state = 'skipped';
        fresh.cursor = idx + 1;
        fresh.awaiting = null;
        writeQueue(fresh);
        renderQueuePanel(fresh, onNewIssue);
      });
      actions.appendChild(skip);
    }

    /* Keď už nie je čo zakladať, „Zrušiť plán" nemá čo zrušiť — je to len
     * odloženie hotového oznámenia. */
    var cancel = document.createElement('button');
    cancel.type = 'button';
    cancel.className = 'ai-assistant-btn';
    cancel.id = 'raa-plan-queue-cancel';
    cancel.textContent = next >= 0 ? planText('queueCancel') : planText('queueDismiss');
    cancel.addEventListener('click', function () {
      dropQueue();
      panel.remove();
    });
    actions.appendChild(cancel);
    panel.appendChild(actions);
  }

  /* Prútik v hlavičke. Odkaz má `href="#"`, lebo obsah okna vzniká celý na
   * klientovi — bez `preventDefault` by prehliadač odskočil na začiatok stránky
   * a do adresy pripísal `#`. */
  document.addEventListener('click', function (event) {
    var link = event.target.closest('a[data-raa="plan"]');
    if (!link) { return; }

    event.preventDefault();
    openPlanDialog(link);
  });

  /* `input` a `change` sú v CAPTURE fáze zámerne: Rich Editor dispatchuje `input`
   * na skrytej textarei a taký event nemusí bublať — capture ho zachytí vždy. */
  function initDraft() {
    // Panel fronty nesúvisí s formulárom novej úlohy — beží aj na detaile úlohy,
    // preto sa volá pred `draftBox` guardom.
    try { initPlanQueue(); } catch (e) {}

    if (!draftBox()) { return; }

    placeDraftButton();
    document.addEventListener('input', syncDraftButton, true);
    document.addEventListener('change', syncDraftButton, true);
    syncDraftButton();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initDraft);
  } else {
    initDraft();
  }
})();
