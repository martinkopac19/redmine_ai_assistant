# Changelog

## 0.6.1 - 2026-09-04

**The summary comes out in the language each person has in My account.** It used to be
English for everyone, because the language was written into the summary prompt by hand.
That mattered more than it looks: of the active people on this instance 58 are on English,
45 on Czech, 4 on Hungarian, 3 on Polish and 1 on Slovak.

- `{{LANG}}` joins `{{NAME}}` as a placeholder in the system prompts and is replaced with
  the reader's language (`Czech (Cestina)`, `Hungarian (Magyar)`, ...) at call time.
  Empty language on the account falls back to the instance default.
- Only the **summary** follows the reader. A reply suggestion is a comment other people
  will read in the issue, so it stays as the prompt defines it.
- The stored prompt had to be migrated, not just the default: `summary_system_prompt` is a
  setting and this instance has its own English version saved, so `DEFAULTS.merge(stored)`
  would have kept "in English" forever. Migration 006 replaces the language wording with
  `{{LANG}}` and adds a line so the section headings get translated too. If it cannot find
  a language phrase it leaves the prompt alone and says so - it does not rewrite an admin's
  own text blindly.
- The cache already keys on the user and a fingerprint of the system prompt, so two people
  in different languages cannot be served each other's summary. Verified rather than assumed.

## 0.6.0 - 2026-09-04

**The model can read the code now.** Until now the only thing it knew about the
implementation was a list of commit subjects. It now reads the merge request linked from
the issue - the description, the code review discussion and the diff - and for a brand new
issue it searches the repository. Off by default; everything below happens only once
`code_context_enabled` is on and a GitLab token is stored.

- **Reply suggestion and summary** follow the *Merge request* link on the issue
  (99.8% of the 8,770 filled values are a plain GitLab URL, so nothing has to be guessed)
  and add the MR title, state, branches, description, **review comments** and the diff.
  Review comments are often the single most useful part: what the reviewer objected to in
  GitLab is usually what the Redmine thread is about.
- **New issue** has no merge request yet, so the only route to the code is a full-text
  search. It reuses the English keywords the model already generates for duplicate
  detection. Which repository belongs to the project is not configured anywhere - it is
  derived from where that project's merge requests actually point (measured: the dominant
  repository covers 76-100% for most projects, and the two that genuinely span two repos
  get both).
- **Secrets are filtered twice.** Whole files are dropped by path (`.env`, `secrets/`,
  `*.pem`, `id_rsa`, `auth.json`, anything with *secret*/*credential* in the name) and
  credential-looking values are masked inside whatever survives. This is not theoretical:
  the very first code search run during development returned
  `config/secrets/prod/prod.RABBITMQ_...php` among three results. A file containing a PEM
  private key block is dropped whole.
- **A merge request link is only followed when it points at the configured GitLab host.**
  The field is free text that anyone can edit, so without that check a link to another
  domain would send the token there.
- **Budgeted.** `code_diff_limit` (default 40,000 characters) caps the diff, and one file
  may take at most a quarter of it; the rest is listed by filename. Measured over 10 recent
  issues, the prompt grows on average from 838 to 19,628 characters - roughly 4,900 input
  tokens per call instead of 210. Worth watching the Gemini bill for a week.
- The GitLab token is stored the same way as the Gemini key: encrypted, never rendered back
  into the page, and an empty field on save keeps the stored value.
- GitLab being unreachable, unauthorised or slow never breaks a suggestion - the code
  section is simply missing, and the reason goes to the log. The test server currently
  cannot reach GitLab at all (its IP is not whitelisted), which is exactly this case.
- `extra/code_selftest.rb` - 55 checks, almost all offline: link parsing including the
  foreign-host rejection, the path filters, the masking, the budget, the off switch,
  graceful degradation, the translations and token storage.

## 0.5.1 — 2026-08-21

**Keyboard shortcut for the AI issue creator: `Ctrl+Shift+X`** (`⇧⌘X` on a Mac). It does exactly
what clicking the wand does, from any page, and the wand now carries a tooltip naming the
shortcut — otherwise nobody would ever find it.

Every more obvious combination was already taken. `Ctrl+K` belongs to the Command Palette (and
to the Rich Editor, for inserting a link); `Ctrl+Shift+K` is the palette too, and the theme
itself synthesises that event when the search magnifier is tapped on mobile; `Ctrl+Shift+A` is
the Rich Editor's attachment picker and opens the add-ons manager in Firefox; and
`Ctrl+Shift+I/J/C/P/M/R/T/N/O` are all browser features. A mnemonic was not available either —
`A` (AI), `I` (issue) and `C` (creator) are each spoken for. Of TipTap's own bindings only
`Mod-Shift-7/8/9/a/b/s` exist, so `X` is free even while the cursor sits in a description.

**The handler deliberately refuses `Ctrl+Alt`.** On Windows, **AltGr** *is* ctrl+alt, and it is
how `@`, `€`, `ł` and `ß` are typed on Czech, Slovak, Polish and Hungarian layouts — which is to
say, by exactly the colleagues this is written for. Without that one condition the window would
pop open while they were typing an email address.

Because it carries a modifier it does not clash with typing, so unlike a bare letter it stays
active inside text fields — you can summon it straight from a half-written description. It is
ignored while a *different* dialog of this plugin is open (two stacked windows is a state this
plugin does not allow), and pressing it again with the window already open just returns focus to
the input rather than building a second one.

The tooltip text comes through `RAA_CONFIG`, not from `init.rb`: `l()` there would be evaluated
once when the plugin loads, freezing whichever language happened to be active at the time.

## 0.5.0 — 2026-08-20

**New: plan mode.** A wand icon sits in the header to the left of the person icon and opens an
**"AI issue creator"** window. You describe the work in your own words and your own
language, and the AI proposes a *plan* — one issue, or a parent issue with subtasks. The
plan can be refined in conversation, and only after **Accept** does anything reach a form.

This is the second way into issue creation. The first one (the button on the new-issue
form) assumes you already know which project the issue belongs to and that you have the
form open. This one starts from "I have an idea, I am not sure where it goes, and it may
be more than one issue".

**The rule has not moved: the module only pre-fills. A human clicks "Create" for every
single issue**, even when there are six of them. The plugin still writes nothing to Redmine.

**Why issues are created one at a time, not in six tabs.** `issue[parent_issue_id]` has to
point at an issue that already exists and is visible (core `issue.rb`), and that id only
comes into being when a human saves the parent. The order is therefore forced by Redmine,
not chosen by us. So after each save a panel appears above the form: "AI plan: 2 of 4
created · Next: …", with a link to the next pre-filled form. The parent gets no
`back_url` (its id is read from the address the core redirects to); subtasks get one, so
you land back where you can see what already stands — and because the URL then carries both
`back_url` and `parent_issue_id`, the core adds its own "Create and follow" button for free.

The queue lives in `sessionStorage`, not on the server: an unfinished plan belongs to *that
tab* and should die with it. It also expires after two hours, so the panel does not surface
next to an unrelated issue you happen to open later. Reading it is deliberately paranoid —
ids are pushed through `/^\d{1,9}$/` and URLs are always assembled by `prefillUrl`, never
taken ready-made from storage, because storage is writable from the browser console and we
build URLs and DOM text out of it.

**One call returns the whole plan.** The enum lists (63 projects, 56 categories, PM
candidates) sit in the schema once, inside `issues[].items`, so the number of subtasks does
not change its size. N separate calls would pay for those lists N times over and the model
would not see the plan as a whole.

**The AI decides whether to split at all.** A single issue is a valid plan; the prompt says
so explicitly, so filing an ordinary bug does not drag you through a wizard. Measured on
the clone: a Slovak request spanning database, API, UI and tests came back as a parent plus
four subtasks with the right categories, while a Polish one-line bug report came back as a
single issue — and the plan summary is written in the language you used, because that part
is for a human, not for Redmine.

**Missing `:manage_subtasks` is handled in three places**, because Redmine drops
`parent_issue_id` *silently* when the permission is absent: the prompt tells the model not
to propose a hierarchy, `resolve_plan` forces `use_parent` to false regardless of what came
back, and the window says why the issues are standalone. The panel additionally notices when
the parent field is missing from the form, which also catches permissions changing midway.

Along the way the modal shell was pulled out into one factory shared by both windows, and
four things the Phase 1 window got wrong were fixed with it: the focus trap only cycled
between two elements (it now collects focusable elements at Tab time, since the body gets
re-rendered), closing did not check that the opener was still in the DOM, the rendered
Markdown was scoped to `#raa-body` by id, and a third keydown listener would have closed two
open dialogs at once.

Two bugs were found by the new tests rather than by using it: the focus filter relied on
`offsetParent`, which is always null in jsdom and unreliable in a browser (it now filters on
the `hidden` attribute), and answering a clarifying question left the submit button disabled,
because it only reacted to the composer — the exact mistake Phase 1 made with "Recalculate".

### Security review before release (21 Aug 2026)

The whole plugin was audited before 0.5.0 was committed — RuboCop (Lint + Security),
ESLint, and a set of measurements against the running clone. Four findings were real and
are fixed here; each was reproduced on the instance first, not inferred from reading code.

**The hourly limit could be walked around.** With the limit set to 1 and already spent,
a request came back `HTTP 429` — but two paid Gemini calls had already gone out. The check
sat at the top of `with_ai_guard`, while picking the project and translating the search
keywords happen *before* it, because their results are what the cache key is built from.
Accounting therefore moved to `ask_model`, which every paid call now goes through: one call,
one unit, checked before the request leaves. A cached answer still costs nothing, because
the cache is read before any call is made.

**A click on the wand cost three calls and was billed as one.** Measured, not estimated:
project pick + keywords + plan. It now subtracts three, so the hourly limit reflects what
is actually spent. At the default of 30 that means roughly ten plans per person per hour;
raise it in the plugin settings if that turns out tight.

**CSRF was not enforced on `.json` routes.** `POST /ai_assistant/plan_issues.json` with a
form-encoded body and no token went through and triggered three paid calls. Redmine skips
token verification for `api_request?`, and that is decided purely by the extension in the
address (core `application_controller.rb:43`). None of these actions is a REST API — our own
JS calls them from the browser and always sends the token — so the controller now declares
that no request of its own is an API request. Cross-site exploitation was already blocked by
the `SameSite=Lax` session cookie; this is the layer that does not depend on that setting.

**The wizard queue mistook a detour for a created issue.** It knew "the issue exists now"
only from standing at `/issues/<id>`. So if you accepted a plan and then, instead of clicking
Create, followed a link to any existing issue, that issue was counted as created — and its
number became the parent, quietly attaching the subtasks to something unrelated (measured on
`#49286`). Arming now happens on the form's `submit` event, so it is the click on Create that
counts, not an address. If validation sends the form back, the flag is cleared again, which
is why an abandoned attempt cannot be credited to a later, unrelated click.

**Plan mode no longer depends on the draft switch.** It asked through
`available_for_draft?`, which requires `draft_enabled` — so the two switches could only be
turned on together, defeating the point of having separate ones.

Not changed, by decision: the project picked by the AI is still not re-checked against
`:add_issues`, and `pick_project` still caches the project object rather than its id. Under
changed permissions or an archived project this can, within the cache hour, build a plan for
a project the user may no longer post to. Judged an edge case and left alone.

Two things the audit confirmed rather than changed, both worth keeping in mind when this code
is touched: **the security boundary is the whitelist, not the prompt** — `IssueDraft.options`
is both the offer to the model and the validation of its answer, so no injected instruction
can widen it — and **nothing is ever rendered through `innerHTML`**. Free-text fields
(`subject`, `description`, `plan_summary`) are the one place injected text can reach, and a
human reads them in the window before anything is saved.

## 0.4.1 — 2026-08-19

**Duplicate search now works in every language.** Issue subjects in Previo are written
in English, but people write their note in their own language — colleagues are in Romania,
Poland and Hungary, and the whole point is that everyone writes their own way and still
gets the full benefit. Duplicate search is a plain `LIKE` over subjects, so that did not
work: the Czech note "nejde ulozit rezervaci kdyz ma host prilis dlouhe jmeno" found 5
issues in Reservations and **not one of them was related** — the only thing that matched
was "host" inside "hostel". The same note in English hit the cap of 40 candidates with
relevant matches at the top.

So a small extra call now turns the note into English keywords before the search runs.
It has to come first, not last: the duplicate candidates belong in the prompt of the main
call, so they cannot be derived from its answer. The prompt asks for hotel-system
terminology (reservation, invoice, voucher, rate, occupancy) rather than a word-for-word
translation, and the answer is cleaned — the model occasionally returns a whole phrase
instead of single words, and words shorter than four characters only add noise to a
`LIKE` search.

**A failed translation never breaks the draft.** If the extra call fails, the search falls
back to the words in the original note and the draft is produced as before. Failing on a
helper step that only exists to improve the main feature would be a bad trade.

One click can now mean up to three paid calls (keywords, draft, and a second draft if the
AI changes the project), but still counts as **one** against the hourly limit. The
translation is cached separately from the draft, so clicking again on the same note does
not pay for it twice. The whole thing has its own switch
(`draft_translate_keywords`, on by default).

## 0.4.0 — 2026-08-19

**New: "Create with AI" on the new issue form.** From a short note in any language the AI
proposes the project, subject, description, tracker, category, priority and the required
custom fields, and warns about issues that may be duplicates.

While the AI works, a "Drafting the issue…" status and a cancel × sit next to the button,
exactly as they do for the reply suggestion. What happens next depends on the AI: if it has
no questions the form is **pre-filled straight away**; if it needs something, an
**"AI issue creator" window** opens with the proposal and an answer field per question. It replaces a Gemini Gem in Google
Chat whose prompt carried a hand-maintained JSON list of projects, categories and project
managers, plus hard-coded description templates. Everything is now read live from Redmine,
so there is nothing left to maintain: this clone has 63 active projects and 464 categories
against the Gem's four projects. The description templates already exist as data in
`global_issue_templates`, keyed by tracker, so they are read from there too — edit the
template in Redmine and the AI follows.

**The form is only pre-filled. "Create" is always clicked by a human**, and saving is still
done exclusively by the core `IssuesController#create`, so every permission and validation
stays where it was. The plugin continues to write nothing to Redmine.

Two things the first version got wrong, both found by using it:

- **The AI could not change the project.** Asked to file a CRM task from the Channel Manager
  form, it had only that project's data to work with, so it kept the task there and invented
  a nonsense "Where?" line to make it fit. It now chooses from every project the user may add
  issues to. Categories, PMs and templates of *other* projects are deliberately not in the
  prompt — that would be 464 categories at once — so when the project changes the model is
  called a second time with the right project's context, which is what finally produced
  "Billing / BILLING - COMMISSIONS" instead of the invented line. Pre-filling then navigates
  to that project's form via URL parameters rather than rewriting the open one, because
  changing the project re-renders trackers, categories and custom fields anyway.
- **The clarifying questions were a dead end** — displayed, with nowhere to answer them. Each
  question now gets its own answer field in the window, and "Recalculate with answers" sends
  the whole conversation back. The server stays stateless; the client holds the history.
  Answering "R+ = 4410, M+ = 4420, from 1 September 2026" put exactly that into the
  "How To Do?" section and the question disappeared.
- **The window opened on every click, even with nothing to ask** — an extra step for no
  reason, and "Recalculate with answers" showed up next to an empty question list. It now
  opens only when there are questions; otherwise the form is filled directly. The stray
  button was a CSS trap worth remembering: `button.ai-assistant-btn` sets `display: inline-flex`,
  which outranks the browser's `[hidden] { display: none }`, so setting `hidden` from JS did
  nothing at all. Anything we hide by attribute now has an explicit `[hidden]` rule.

Notes on how it is built, because each point cost a debugging round:

- **The model returns names, not ids, and the server resolves them.** `options` is one method
  used for both the prompt and the validation, so the offered list and the accepted list
  cannot drift apart. Anything that does not resolve is dropped — an empty field beats a
  wrong one.
- **The response schema is built dynamically, with an `enum` per field.** With plain string
  fields the reasoning model wrote its train of thought into `tracker`
  ("Bug McBugface? No, Bug tracker from list…"), which then matched nothing. An `enum` leaves
  it nowhere to wander. Gemini rejects an empty string in an `enum`, so `__UNKNOWN__` is the
  sentinel for "not sure"; no Redmine record is named that, so it resolves to nothing by itself.
- **Optional keys are simply omitted by Gemini**, so the fields that matter are listed in
  `required` — in the first test neither the category, the priority nor the PM came back.
- **A truncated JSON now reports "raise the token limit", not "unexpected format".** For a
  reasoning model the thinking counts against `maxOutputTokens`, so 4096 returned an object
  cut in half; the default for this feature is 16384.
- **Duplicate candidates cannot use the core `Issue.like` scope**, which joins words with AND
  and would require the whole sentence to appear in a subject. Ours ORs the words and ranks by
  how many matched, then the model re-ranks and flags only what it believes. Known limit:
  matching is keyword-based, so a note written in Czech against English-language issues finds
  less than an English one would.
- **Required `bool` custom fields are not offered to the model.** Previo requires "DEV ready",
  which is a workflow flag rather than something contained in a bug report.
- **The assignee is not proposed by the model at all.** When the chosen category has an
  `assigned_to` in Redmine it is filled in from there — deterministic, and free.
- **The button sits next to the "New issue" heading**, rendered from
  `view_issues_new_top` and moved into the `<h2>` by JS. The first attempt used
  `view_issues_form_details_bottom`, which put it adrift in the middle of the field list;
  worse, anything rendered inside the form is re-created whenever changing the tracker or
  the category makes Redmine re-render `#all_attributes` from the server, so a moved copy
  would have come back as a duplicate. `view_issues_new_top` is outside the form and fires
  only on the new issue page, which removes both problems. The warnings panel is built by
  JS below the same heading, for the same reason.
- **The project is read from `#issue_project_id`, not from the button**, so changing the
  project in the form (or picking one on the global `/issues/new`) doesn't hand the AI the
  categories, PM and templates of the previous project.

## 0.3.2 — 2026-08-06

Two findings from a review of 0.3.1, both about things that only bite later:

- **Fix: editing a prompt appeared to do nothing — for both buttons.** The cache key held
  the issue and the user but not what was actually being sent, so after changing a prompt
  (or the model, or a description limit) the next click returned the hour-old answer and the
  change looked broken. This hit the reply suggestion exactly as it hit the summary, since
  both go through the same code path. The key now carries a digest of both prompts and the
  model, so tuning takes effect on the very next click while genuinely unchanged requests
  still cost nothing. Reverting to a previous prompt even re-uses its old cached answer,
  because the digest is deterministic.
- **Fix: a long summary could not be scrolled by keyboard.** The overlay body scrolls but a
  plain `<div>` cannot take focus, and the focus trap pinned Tab to the close button, so
  there was no way to reach the text without a mouse. The body is now focusable and part of
  the trap, and carries `aria-live="polite"` so a screen reader announces the summary
  replacing "Generating…".

## 0.3.1 — 2026-08-06

- **Fix: the summary showed its Markdown raw** — section headings arrived as
  `**Kde to stojí**` instead of bold. Headings, bullets and `` `code` `` are now rendered,
  but by **building DOM nodes** (`createElement` / `createTextNode`), never `innerHTML`:
  model output is untrusted input, and `innerHTML` would turn it into live HTML.
  Deliberately narrow — only `**bold**`, inline code, bullets and a fully bold line as a
  heading; anything else stays text, which beats a half-complete Markdown parser.
- Added `extra/overlay_test.js`, a jsdom test of the client side (23 assertions): the button
  really lands between *Edit* and *Log time*, the Markdown renders, `<img onerror=…>` from the
  model stays text, and the overlay closes on ×, Esc and a click outside.

## 0.3.0 — 2026-08-06

**AI Summarizer.** A second button — in the issue action bar between *Edit* and *Log time*, with a
wand icon — opens an overlay above the issue holding a summary of the **description and every
public comment**. On a 30-comment issue that is the difference between reading the thread and
knowing where it stands. The summary is only displayed: it is never inserted anywhere, and the
plugin still writes nothing to Redmine.

- The overlay closes with **×**, **Esc** or a click outside, and closing it **aborts the request**,
  so a misclick costs no waiting. Model output goes into the DOM via `textContent`, never
  `innerHTML`.
- **Two separate prompts in the configuration**, each labelled with the button it drives: one for
  the reply suggestion, one for the summary. The *shape* of the summary (sections, length,
  language) lives in that prompt rather than in the code, so it can be changed without touching
  the plugin.
- **Its own description limit** (default 4000 vs the reply's 600 — a summary stands on the
  original request, which is exactly what gets truncated otherwise). `0` means no truncation.
- The hourly per-user limit is deliberately **one counter for both features** — they bill to the
  same shared key. Summaries are cached per issue + last comment for an hour, under their own key.
- Privacy is unchanged and separately asserted for the new path: private notes and private issues
  never reach the summary either.

No migration needed — the new settings fall back to their defaults on their own.

## 0.2.3 — 2026-08-05

- A **cancel “×”** now sits next to the *Generating…* status, for misclicks. It
  aborts the request (`AbortController`), so nothing is inserted into the comment
  field. The call already sent to Gemini is not stopped and still counts against
  the hourly limit — but the next click on the same issue comes from the cache.

## 0.2.2 — 2026-08-05

- **Fix: the page jumped up to the description after generating a suggestion.**
  The issue page has two Rich Editor instances — description and comment — and
  both carry the `.re-editor` class, so an unscoped selector focused the
  description editor, which sits high up in the DOM. The comment editor is now
  located inside `.re-comment-box`, and focus is taken with `preventScroll`, so
  the view stays where the button is.

## 0.2.1 — 2026-08-05

- Removed the **data-transfer acknowledgement** checkbox and the GDPR note from
  the plugin configuration. The plugin is now gated by the stored key plus the
  enable switch only; off is still the default. Migration `005` drops the stored
  `gdpr_ack` value so it cannot linger as a dead setting.
- The privacy behaviour itself is unchanged: private notes and private issues are
  still never sent, and the reasoning is documented in the README.

## 0.2.0 — 2026-08-05

First published version. Switches the provider to **Google Gemini** and moves
from per-user API keys to **one shared key managed by an administrator**.

- **AI reply suggestion** button next to *Add comment* on the issue page. It
  drafts a reply from the issue's own context and inserts it into the comment
  field; the user reviews, edits and submits it themselves, under their own
  account. The plugin never writes to Redmine.
- **One shared Gemini API key**, entered only by an admin in the plugin
  configuration. Stored encrypted (`ActiveSupport::MessageEncryptor`, key derived
  from `secret_key_base`) and **never sent to the browser** — the field always
  renders empty and only the last four characters are shown, so the key cannot be
  read via Inspect element. An empty field means *keep the stored key*; a separate
  checkbox removes it.
- Requires both the key and the enable switch before anything is sent anywhere.
  Off is the default. (0.2.0 also required a data-transfer acknowledgement
  checkbox; that was dropped in 0.2.1.)
- Context sent to Gemini: subject, status, priority, author, assignee, the
  (truncated) description, **all public comments**, and linked **changesets**.
  Private notes and private issues are never sent, regardless of permissions.
- Per-user hourly call limit (atomic via `Rails.cache.increment`) protects the
  shared budget. Suggestions are cached per issue + last comment for an hour, so
  clicking again without a change costs nothing.
- Errors surface as HTTP 4xx/5xx with a readable message — never as a "reply"
  containing an error string. Handles invalid key, exhausted quota, Gemini safety
  blocks, truncated output, timeout and network failure.
- `extra/selftest.rb` verifies encryption, key storage (empty / new / clear), that
  the key is absent from the rendered HTML, the enable gating, the privacy filters
  in both directions, routes, locales, partials, and the live HTTP path.

### Notes for anyone reading the code

- The key lives in the plugin settings hash but is written through a `prepend` on
  `SettingsController#plugin`: Redmine has no hook for saving plugin settings, and
  without it an empty field would wipe the stored key on every save. The patch is
  scoped to this plugin by `params[:id]`.
- Do **not** override `render_error` in a Redmine controller —
  `ApplicationController#render_error(arg)` exists and is used by the CSRF and
  error-page handling. Overriding it with a different arity turns a clean 422 into
  a 500. Ours is `render_json_error`.
- Merge requests are **not** read. Redmine stores the MR only as a link-format
  custom field and never fetches it. Linked merge commits do carry the MR title
  and reference, so that much arrives through changesets for free.
