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
    var box = document.querySelector('.ai-assistant-actions');
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

  function init() {
    watchForCommentBox();
    placeSummaryButton();
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

  // Esc a focus trap. Listener je na document v capture fáze, aby predbehol
  // Redmine handlery (rovnako to robí command palette).
  document.addEventListener('keydown', function (e) {
    if (!overlayOpen()) { return; }

    if (e.key === 'Escape') {
      e.preventDefault();
      e.stopPropagation();
      closeOverlay();
      return;
    }

    if (e.key === 'Tab') {
      // V okne je jediný fokusovateľný prvok (×), takže fokus držíme na ňom.
      e.preventDefault();
      focusQuietly(ov.close);
    }
  }, true);

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
})();
