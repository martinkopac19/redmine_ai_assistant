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

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', watchForCommentBox);
  } else {
    watchForCommentBox();
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
})();
