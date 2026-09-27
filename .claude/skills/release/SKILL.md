---
name: release
description: Release the current head of main as a new version of The City. Checks main is clean, pushed and green in CI, writes the CHANGELOG section from what changed since the last tag, then commits, tags, pushes and watches CI until the GitHub release and Sparkle appcast are live.
argument-hint: "[version]"
disable-model-invocation: true
---

# Release The City

Releases `HEAD` of `main` on `Slaymish/theCity`. Pushing a `vX.Y.Z` tag makes `.github/workflows/ci.yml` build the app, sign the update, and publish the `.dmg`, `.zip` and `appcast.xml`. The release notes come from the `## X.Y.Z` section of `CHANGELOG.md`, and that section is also what Sparkle shows users in the update dialog. So the section is the release: it has to be accurate and it has to cover only this release.

Stop and report at the first failed check. Don't work around it.

## 1. Preflight

Run these from the repo root. `gh` has two accounts; this repo belongs to **Slaymish**, so run `gh auth switch --user Slaymish` first and switch back to `hamishburke` at the end, including when you stop early.

1. `git fetch origin --tags`.
2. The current branch is `main`, `git status --porcelain` is empty, and `git rev-parse HEAD` equals `git rev-parse origin/main`. If local is ahead, ask whether to push first. The commits being released must have their own green CI run.
3. CI is green for `HEAD`: `gh run list -R Slaymish/theCity --workflow CI --commit "$(git rev-parse HEAD)" --json status,conclusion,databaseId`. If a run is in progress, `gh run watch <id> -R Slaymish/theCity --exit-status`. If it failed or there isn't one, stop.
4. The signing secret exists: `gh secret list -R Slaymish/theCity` lists `SPARKLE_ED_PRIVATE_KEY`. Without it the release job fails after the tag is pushed.

## 2. What changed

1. Last release: `git describe --tags --abbrev=0 --match 'v*'`. If there's no tag, this is the first release: the top `CHANGELOG.md` section is already written, so use its version, show it to the user and skip to step 4 (tag only, no commit).
2. If `git rev-list LAST..HEAD --count` is 0, stop: nothing to release.
3. Read the changes since the last tag only:
   - `git log --no-merges --format='%h %s%n%b' LAST..HEAD`
   - `git diff --stat LAST..HEAD`
   - the diff itself (`git diff LAST..HEAD -- App Packages project.yml`) wherever a commit message doesn't make the user-visible effect clear.

## 3. Draft the version and notes

**Version** (semver, pre-1.0): new features or behaviour changes bump the minor version (`0.1.3` → `0.2.0`), and fixes only bump the patch (`0.2.0` → `0.2.1`). If the user passed a version as the argument, use that. It must be greater than the last tag.

**Notes:** a list of bullets for what a user of the app would notice since the last release, and nothing else.

- One sentence per bullet, saying what changed and where in the app it shows up. "Floors now remember their camera angle between launches" is good. "Improved the floor view" isn't.
- Leave out internal changes: refactors, tests, CI, tooling, docs, dev scripts. Only mention them if they change something for users, such as a new minimum macOS version or a data migration.
- Only claim what the diff shows. Don't repeat anything already in an earlier `CHANGELOG.md` section.
- Put new things first, then changes, then fixes ("Fixed …"). Add `### Added / Changed / Fixed` subheadings only if there are more than about eight bullets.
- Use UK English, match the tone of the existing CHANGELOG, and don't use marketing words.
- If nothing user-facing changed, say so and ask whether to release anyway.

Show the version and the exact section to the user with AskUserQuestion: release as shown, change the version, or edit the notes. **Their approval is the explicit instruction to commit, tag and push for this run.** Without it, don't commit.

## 4. Commit, tag, push

1. Insert the section directly below `# Changelog` in `CHANGELOG.md`, as `## X.Y.Z`, a blank line, then the bullets. Skip this on a first release.
2. `git add CHANGELOG.md && git commit -m "Release X.Y.Z."`. Commit only that file.
3. `git tag -a vX.Y.Z -m "The City X.Y.Z"`
4. `git push --atomic origin main vX.Y.Z`

## 5. Watch and verify

1. Find the tag's run: `gh run list -R Slaymish/theCity --workflow CI --branch vX.Y.Z --json databaseId,status` (retry for up to a minute until it appears), then `gh run watch <id> -R Slaymish/theCity --exit-status`.
2. If the run fails, show `gh run view <id> -R Slaymish/theCity --log-failed | tail -60` and diagnose. Nothing is published unless the `Publish release` step ran, so the usual fix is to fix `main`, delete the tag (`git push origin :refs/tags/vX.Y.Z && git tag -d vX.Y.Z`) and tag again. Ask before deleting a tag, and never delete one that already has a published release: fix forward with a new patch version instead.
3. Check the release is right:
   - `gh release view vX.Y.Z -R Slaymish/theCity --json isDraft,isPrerelease,assets,body`: not a draft or prerelease, the assets are `TheCity-vX.Y.Z.dmg`, `TheCity-vX.Y.Z.zip` and `appcast.xml`, and the body matches the CHANGELOG section.
   - `curl -fsL https://github.com/Slaymish/theCity/releases/latest/download/appcast.xml | grep -o '<sparkle:shortVersionString>[^<]*'` shows `X.Y.Z`. This is the URL installed copies check for updates.
4. Switch `gh` back to `hamishburke`, then report the release URL and the notes you published.
