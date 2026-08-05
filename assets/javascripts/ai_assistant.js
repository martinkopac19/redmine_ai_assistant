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

  function post(path, payload) {
    return fetch((CFG.base || '') + path, {
      method: 'POST',
      credentials: 'same-origin',
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'X-CSRF-Token': csrfToken()
      },
      body: JSON.stringify(payload)
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

  /* Textarea #issue_notes je pri aktívnom Rich Editore skrytá, ale ten si
   * prepísal jej `value` setter tak, že zápis prepíše aj obsah editora.
   * Stačí teda nastaviť value; fokus dávame editoru, nie skrytému poľu. */
  function insertText(text) {
    var field = document.getElementById('issue_notes');
    if (!field) { return; }
    field.value = text;

    var editable = document.querySelector('.re-editor [contenteditable="true"]');
    if (editable) {
      editable.focus();
    } else if (field.offsetParent !== null) {
      field.focus();
    }
  }

  document.addEventListener('click', function (event) {
    var btn = event.target.closest('.ai-assistant-btn[data-raa="suggest"]');
    if (!btn) { return; }
    event.preventDefault();

    var scope = btn.closest('.ai-assistant-actions');
    if (!scope) { return; }

    btn.disabled = true;
    setStatus(scope, btn.getAttribute('data-working') || '', false);

    post(CFG.suggestPath, { issue_id: scope.getAttribute('data-issue-id') })
      .then(function (data) {
        insertText(data.text);
        setStatus(scope, '', false);
      })
      .catch(function (err) {
        setStatus(scope, err.message, true);
      })
      .finally(function () {
        btn.disabled = false;
      });
  });
})();
