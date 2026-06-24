# Fork notes — before-effects

This repo is a **customized fork** of [palmier-io/palmier-pro](https://github.com/palmier-io/palmier-pro)
(Palmier Pro). It tracks upstream so we get their updates, while carrying our own changes on top.

## Remotes

| Remote     | Repo                                  | Use                         |
| ---------- | ------------------------------------- | --------------------------- |
| `origin`   | `NarayanaSabari/before-effects`       | our fork — push here        |
| `upstream` | `palmier-io/palmier-pro`              | upstream — pull updates from here |

If `upstream` is missing on a fresh clone:

```bash
git remote add upstream https://github.com/palmier-io/palmier-pro.git
git fetch upstream --tags
```

## Branch model

`main` **is our product** and tracks `origin/main`. We pull upstream updates by **merging**
`upstream/main` into `main` (no rebase, no force-push — safe for tags and collaborators).

- See only our own changes at any time: `git diff upstream/main...main`
- See what upstream has that we don't: `git log --oneline main..upstream/main`

## Pulling upstream updates

Use the helper (preview → merge → build):

```bash
scripts/sync-upstream.sh --check     # preview what's new, no changes
scripts/sync-upstream.sh             # merge upstream/main into current branch, then build
scripts/sync-upstream.sh --no-build  # merge only
```

Do it **often** — small frequent merges beat one giant painful one. `git rerere` is enabled, so a
conflict you resolve once is auto-replayed on later merges.

## Golden rule: add, don't edit

Merge pain is proportional to how many of upstream's files we modify. New files never conflict;
edited files do.

- **Prefer new files** — a new effect, agent tool, panel, or view.
- **Avoid editing upstream's churn hot-spots** unless necessary. These change constantly upstream:
  `Editor/ViewModel/EditorViewModel+*.swift`, `Timeline/TimelineView.swift`,
  `Generation/UI/GenerationView.swift`, `Agent/Tools/ToolDefinitions.swift`.
- When you must change core behavior, use the smallest hook (add an extension/method) rather than
  rewriting an existing function — keep the conflict surface to a line or two.
- Tag our commits with a `[fork]` prefix so they're easy to find, reorder, or drop.

### Low-conflict seams in this codebase

| To customize…              | Do this                                                        |
| -------------------------- | ------------------------------------------------------------- |
| Backend keys / secrets     | `.env` / `.env.prod` (gitignored — never conflicts). See `.env.example`. |
| New AI agent tool          | Add `Agent/Tools/ToolExecutor+Yours.swift` + one registration line |
| New effect / filter        | Add a `.metal` kernel + descriptor; `EffectRegistry` is additive |
| New panel / inspector tab  | New SwiftUI files                                             |
| Branding (colors, fonts)   | `UI/AppTheme.swift` values (one central file)                |
| App name / icon / bundle id / appcast | `Resources/Info.plist`, `Resources/AppIcon.*`, `appcast.xml`, `scripts/` |

## Customization log

Record every intentional divergence from upstream here, so merges and audits stay sane.

| Date | Area | What & why |
| ---- | ---- | ---------- |
| _(none yet)_ | | |

## Config & secrets

Secrets are injected into `Info.plist` at build time by `scripts/bundle.sh` from `.env`
(or `.env.prod` for release). Nothing secret is committed (`.env*`, `*.provisionprofile`,
`AuthKey_*.p8`, `secrets.json` are all gitignored). Copy `.env.example` to `.env` to get started.

**The editor runs fully without any backend.** With no keys set, `AccountService` flags itself
misconfigured and the UI hides AI/generation/account features — the timeline editor, local MCP
server, on-device search, and transcription all still work.

## Distribution checklist

> Decide: **personal/internal use** (you can stop here) vs **shipping your own builds**.

For personal/internal use, no extra steps — `swift run` or a local `scripts/bundle.sh debug`.

To distribute your own auto-updating builds, you need your **own** of each (upstream's are Palmier's):

- [ ] Backend: your own Convex + Clerk (+ Stripe) project, keys in `.env.prod` — *only if you want AI/account features*
- [ ] Code signing: your own `Developer ID Application` identity + provisioning profile (`SIGNING_IDENTITY`, `PROVISION_PROFILE`)
- [ ] Notarization profile (`NOTARY_PROFILE`)
- [ ] Bundle identifier in `Resources/Info.plist`
- [ ] App name / icon (`Resources/AppIcon.*`, `CFBundleName`)
- [ ] Sparkle appcast URL (`SUFeedURL` in Info.plist) + your own EdDSA key (`SUPublicEDKey`) → host your own `appcast.xml`
- [ ] Sentry project (optional): `SENTRY_DSN`, `SENTRY_AUTH_TOKEN`, `SENTRY_ORG`, `SENTRY_PROJECT`

## License

Upstream is **GPLv3**. Personal/internal use carries no extra obligations. If you **distribute** a
modified build, you must also make your source available under GPLv3.
