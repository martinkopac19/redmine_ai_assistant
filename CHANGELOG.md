# Changelog

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
