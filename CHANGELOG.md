# Changelog

## 0.2.1 — 2026-08-05

- Removed the **data-transfer acknowledgement** checkbox from the plugin
  configuration. The plugin is now gated by the stored key plus the enable switch
  only; off is still the default. Migration `005` drops the stored `gdpr_ack`
  value so it cannot linger as a dead setting.
- The GDPR note under the configuration form stays — the privacy behaviour itself
  is unchanged: private notes and private issues are still never sent.

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
