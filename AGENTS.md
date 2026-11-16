<!-- BEGIN brew-shared (synced from ~/Desktop/code/bufferbrew/brewapps/AGENTS.md by sync-agent-rules.sh; do not edit here) -->

# Brew ecosystem — shared agent rules

Rules for every app in the Brew family (`bufferbrewlabs` GitHub org). They apply to
any coding agent — Claude Code, Codex, Cursor, Gemini, Copilot — working in
any Brew repo. App-specific rules live in that repo's own `CLAUDE.md` /
`AGENTS.md` below the shared block; where the two conflict, the app's own
rules win for that app.

Canonical source: `~/Desktop/code/bufferbrew/brewapps/AGENTS.md`. Each repo carries a synced
copy between `brew-shared` markers — edit the canonical file, then run
`~/Desktop/code/bufferbrew/brewapps/sync-agent-rules.sh`. Never edit the synced block in place.

## Members

Brew apps live under `~/Desktop/code/bufferbrew/brewapps/`, one git repo per folder:
BREW, BrewHire, BrewTales, BrewVoyage, Kurio, Synapse, Auri, WealthBrew.
BrewVoyage as a standalone app was retired 2026-11-16; its trips live in Nook's
`voyage` schema.
Synapse was NeuroBrew until 2026-11-07. Kurio was BrewWire until 2026-11-14. BrewSkolar was merged into
Synapse and retired (2026-10-05). BrewFeed was retired 2026-11-13 (repo
archived, `brewfeed` schema dropped); its Blogging work moved to BREW.

Not Brew, whatever older docs say: `craftsman`, `castack`, `WinCtrl`,
`LitmusLLM`. Don't rename those or fold them into Brew docs.

## App boundaries

Before adding a feature, check it belongs to the app you're in:

| App | Owns | Rule |
|---|---|---|
| Kurio | News APIs, RSS, sports, and the daily AI brief with its collector | Pulls from external sources? It goes here |
| BREW (Nook) | Blogging Studio: articles, editor, comments, rubric scoring, notes, Medium stats | Writing and editing your own posts? It goes here |
| Synapse | Courses, deep dives, voiceover, learning progress from a topic or source | The goal is to understand something? It goes here |

Apps hand off to each other by link only (e.g. a Kurio story opens
Synapse's new-course screen with `?topic=`). They never read each other's
schema.

## Naming

- Every app has a one-word product name (e.g. Synapse) and sits under one
  umbrella, Brew: present it as "<Name> · a Brew app", target the `bufferbrewlabs`
  org, and build on the shared `brew-packages` (code, theme, icon style).
  Apps are being renamed one at a time; older `<Thing>Brew` names stay until
  their turn. No ad-hoc names: agree a new name before using it.
- Supabase Edge Function slugs are flat across the shared project, so prefix
  them with the app: `kurio-*`, `synapse-*`, `wealthbrew-*`, `core-*`.

## Repo hygiene

- Each folder is its own repo with its own remote and dependencies. `cd` into
  it and treat it as the root; never edit or commit in a sibling app as a
  side effect.
- Stage files by name. No `git add -A` / `git add .`.
- **Never commit `graphify-out/`** — not even as a separate graph commit. If an
  app's own docs say to commit the graph, flag the conflict instead.
- Shared Flutter code lives in `bufferbrewlabs/brew-packages`
  (`~/Desktop/code/bufferbrew/brewapps/packages`, a pub workspace). Only schema-agnostic
  client code belongs there — HTTP/LLM provider dispatch, Supabase bootstrap,
  auth helpers — never a repository class tied to one app's tables.
- Apps depend on it by **git dep pinned to the commit SHA of a release tag**,
  with the tag in a comment (`ref: 9102a5b… # v0.2.2`), never a committed
  `path:` dep — a fresh clone of one app must build on its own. Not the tag
  name: brew_auth/brew_ui reach brew_core by an in-repo path, which pub records
  as the SHA, and a tag-name ref then counts as a different source and fails
  to resolve. Get the SHA with
  `git ls-remote https://github.com/bufferbrewlabs/brew-packages.git 'refs/tags/vX.Y.Z^{}'`.
  To develop against a local checkout, add a git-ignored
  `pubspec_overrides.yaml` pointing at `../packages/<pkg>` — only
  while you're editing the package. It rewrites `pubspec.lock` to a `path:`
  source; never commit the lock in that state. Delete the override, tag a
  brew-packages release, bump `ref`, `pub get`, then commit.

## Supabase projects

Brew runs on **two** Supabase projects (both eu-west-1). Nook has its own since
2026-11-16 (`BREW/docs/30-Nook-Project-Move.md`); everything else still shares
the old one.

| Project | Ref | Apps |
|---|---|---|
| **Nook** ("nook") | `lijzebwgdvlywsspxjvv` | BREW (Nook) only: schemas `public`, `core`, `voyage` |
| **Shared** ("brew", was "AI Dashboard") | `torjnuovzvjgmkzokvfw` | Kurio, Synapse, WealthBrew, BrewHire |

Nook's service-role key reaches nothing else, and the other apps' keys reach
nothing of Nook's. Each project has its **own** `core`: a Nook app and a
shared-project app never meet through `core`; they hand off by link only.

On the shared project, apps are isolated by **Postgres schema**:

| Schema | Owner |
|---|---|
| `public` | Synapse's `syn_*` and the `content_*` pipeline (Nook's tables there are retired; docs/30 Phase 7) |
| `core` | cross-app contract layer on that project — app registry, outbox, shared LLM keys/connections. Every app may write its own rows |
| `kurio` | Kurio |
| `hire` | BrewHire |
| `wealth` | WealthBrew |

All of these fail silently if ignored:

- **No app reads another app's schema.** The only crossing point is `core.*`;
  cross-app data travels as a denormalized push into the `core.app_events`
  outbox. Why: `BREW/supabase/migrations-archive/0040_core_schema.sql`.
- **A new schema must be exposed** under dashboard → Project Settings → Data API
  → Exposed schemas (`PGRST106` otherwise). No SQL/CLI equivalent. Procedure:
  `BREW/docs/22-Core-Cutover-Runbook.md` (historical; same dashboard step).
- **Every client names its schema**, service-role clients included —
  service_role bypasses RLS, not PostgREST schema routing.
- **Check the project ref before any push, deploy or SQL.** A command run
  against the wrong project fails quietly or, worse, succeeds. Nook's scripts
  default to `lijzebwgdvlywsspxjvv`; everything else is `torjnuovzvjgmkzokvfw`.
- **`supabase db push` from `BREW` goes to the Nook project only**, and only
  `BREW/supabase/migrations/` (four baseline versions from 2026-11-15/16; the
  old 107 files are in `migrations-archive/`). The **shared** project's ledger
  still lists BREW's old history plus the satellites', so never run `db push`
  against it: a push from any app fails with `LegacyDbPushMissingLocalError`,
  and never run the `migration repair --status reverted` it suggests — that
  rewrites another app's history. Satellites apply migrations via the Supabase
  MCP or SQL editor, then `supabase migration fetch` into a scratch dir and
  copy their own file back into the repo.
- **Fresh installs use bundles, not migrations.** An install onto a new
  Supabase (self-hosting, a standalone app) runs brew-packages'
  `supabase/core/` bundle and then the app's own `supabase/bundle/`, via
  `brew-migrate` (brew-packages `supabase/README.md`). So a schema change goes
  in **two** places: a migration for the live project, and a new
  `supabase/bundle/000N_….sql` (or `supabase/core/000N_….sql` for `core`) for
  fresh installs. Never edit an applied bundle file; brew-migrate refuses it.
- **A bundle built from `supabase db dump` loses grants.** The dump drops
  EXECUTE revokes and the anon/authenticated table grants, so every function
  and table comes back open to the public anon key (found on the Nook project,
  2026-11-16). After building or restoring a database, diff
  `has_function_privilege` / `has_table_privilege` for `anon` and
  `authenticated` against the source, and run the security advisor.
- **Test users:** one `auth.users` row serves every app **on a project** —
  triggers fan signups out to `public.users`, `kurio.users`, `hire.users`.
  Use the shared test account `brew.test01@example.com`; don't create per-app
  test users. It exists on both projects (the Nook copy has the same password
  hash). Its password is in
  `~/Desktop/code/bufferbrew/brewapps/.secrets/test-user.env`
  (`BREW_TEST_PASSWORD`, outside every repo). Read it into a variable or env
  file only — never print, echo, log, paste into chat, or commit it. To reset
  it, hash locally and update `auth.users`; don't put the plaintext in SQL.
- **Keys:** apps use `sb_publishable_…` and `sb_secret_…` keys, one pair per
  app where the project allows it, not the legacy anon/service_role JWTs (which
  are being retired; BREW docs/30). A service-role call must never reach a
  log, a chat or a commit.

## No GitHub Actions; deploy after every merge

GitHub Actions is off for every Brew repo (2026-11-14: no paid CI; the
workflows were removed). Nothing runs on push, so the agent does the checks
and the deploy:

- **Before merging:** run the repo's own checks locally (its `CLAUDE.md`
  lists them, e.g. `flutter analyze`, `flutter test`, the MCP server build)
  and report the real results.
- **After every merge to the default branch** of an app with a web build,
  deploy it from this Mac:
  `~/Desktop/code/bufferbrew/brewapps/deploy-vercel.sh <App>`
  (BREW, Kurio, Synapse, WealthBrew, BrewHire; `all --if-changed` does every
  app whose default branch moved). It deploys `origin/<default>` from a
  `git archive` copy, so local branches, uncommitted work and untracked
  files never ship. Report the change as live only after it prints `Ready`.
- Batch merges: deploy once after the last merge, not per merge.
- No preview deploys. Vercel's Git integration is not used (Hobby can't
  connect private org repos).
- Don't add workflows back without the owner's say-so; a local CI/CD runner
  may replace this later.

## Pending user actions (Notion)

Every job in a Brew app ends by updating that app's pending user actions in
Notion, under **Brew Labs › Brew Apps Index**, one child page per app (e.g.
"WealthBrew — what's done and what's left"). Applies at all times, to every
job, whatever its size.

- Add anything only the user can do: secrets and API keys, dashboard toggles
  (exposed schemas, OAuth), store/signing steps, device checks, decisions.
- Tick or remove items that are done, after checking the live state (e.g. a
  SQL query for Vault secrets), not from memory.
- No page for the app yet: create one under Brew Apps Index.
- The older "Steps for Live" database under bufferBrew Repos is not the target.
- **Temporary fallback file.** If Notion is unavailable, the tool call fails,
  or the update can't be finished in this job, write the pending items to
  a persistent local file first:
  `~/Desktop/code/bufferbrew/brewapps/.pending-actions/<App>.md` (one file per
  app, outside every repo, so nothing gets committed). Each entry is a
  checkbox line with the date and the reason it is not yet in Notion. The
  next job that reaches Notion for that app pushes the entries to the app's
  page and then removes them from the file. Never treat an item as done
  because it sits in the file; it counts as pending until it is on the Notion
  page.
- **Batch Notion writes.** Collect pending items in the job's local file as
  they come up, then update Notion once at the end of the job, in a single
  call that carries every change (adds, ticks and removals together). Don't
  call the Notion MCP once per item; each extra call is more to fail and to
  rate-limit.

## Latest APKs in Google Drive

Every app with an Android build keeps its latest APK in the one `apk` folder
at the top of My Drive. On the Mac that is exactly
`~/Library/CloudStorage/GoogleDrive-<account>/My Drive/apk` (directly under My Drive).
Never write to a nested `apk` folder, an `apk (1)` duplicate or anywhere else.
If the folder is missing, or Drive has made a duplicate, stop and tell the
user; don't create a new one. Whenever a job lands changes on an app's
default branch:

- Build the APK from the default branch (release where it builds, else debug),
  using the file name already in the folder (`<App>-release.apk` /
  `<App>-debug.apk`).
- Check it with `apksigner verify`, then overwrite the old file.
- After a replacement APK passes signature verification, remove stale APKs for
  that same app from that folder (including superseded debug/release variants).
  Keep one latest verified APK per app; never remove another app’s APK.
- Note it on the app's Notion page. Overwriting can change the Drive file id,
  so re-check any Notion link to the file.

<!-- END brew-shared -->
