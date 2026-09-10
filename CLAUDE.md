# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`labprof` — a Windows PowerShell tool that removes the repeated Google login on a school lab PC that wipes
everything except `D:` on shutdown. It does not automate typing — it makes login unnecessary by
keeping a logged-in Chrome profile inside an AES-256 encrypted container on `D:`, decrypting it to a
`C:` temp folder for the session, and re-encrypting on Chrome exit. `README.md` is the end-user
manual (Korean) and doubles as the spec; read it before changing behavior.

The name is load-bearing in three places that must keep agreeing with each other: the container
magic `LABPROF1`, the `LP_` variable prefix, and the `*-LP*` function names. Renaming the project
would mean renaming those, and changing the magic string makes every existing container unopenable
— so don't. The folder users actually see on `D:` is a separate, user-facing choice
(`D:\GoogleLab\` in the docs) and can be anything.

**All user-facing strings are Korean. Keep them Korean.**

## Commands

There is no automated test suite in the repo — it was deleted deliberately so the folder that ships
to `D:` is only what the user runs. Verification is now (a) the parser check below, (b) dot-sourcing
the libraries and calling functions directly, and (c) `CHECKLIST.md`, the by-hand 2-person procedure
that has to happen in the lab anyway. If you make a non-trivial change to `crypto.ps1`,
`profile-lib.ps1`, or `slots.ps1`, write a throwaway script in `$env:TEMP`, run it, and delete it —
do not add a test file here without being asked.

```powershell
# Syntax check every script without executing it
Get-ChildItem *.ps1 | ForEach-Object { $t=$null; $e=$null;
  [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$t,[ref]$e)
  if ($e.Count) { "$($_.Name): $($e[0].Message)" } else { "ok $($_.Name)" } }
```

To work on one area interactively, dot-source the libraries and call functions directly — they have
no load-time side effects:

```powershell
. .\crypto.ps1; . .\profile-lib.ps1; . .\slots.ps1
$script:LP_Iterations = 2000        # keeps PBKDF2 fast while iterating
```

Entry points (`lab-profile.ps1`, `change-password.ps1`, `collect-env.ps1`) are interactive and
prompt with `Read-Host -AsSecureString`, so they cannot be driven from piped stdin — exercise the
libraries instead, and run the entry points by hand.

## Architecture

Four layers, dot-sourced bottom-up, plus a small logging helper alongside them:

- **`crypto.ps1`** — container format and nothing else. No Chrome knowledge, no file layout
  knowledge. `Protect-Container` / `Unprotect-Container` (dir <-> container),
  `Convert-ContainerPassword` (re-encrypts the zip bytes without unzipping),
  `Test-LPContainer` (MAC-only verify), plus the `Protect-LPFile` / `Unprotect-LPFile` primitives.
- **`profile-lib.ps1`** — Chrome and profile concerns: `Find-LPChrome`, `Get-LPChromeCount`,
  `Wait-LPChromeExit`, `Remove-LPProfileCaches`, `Save-LPContainer`, `Remove-LPWorkDir`.
  Split out from the entry point specifically so the tricky parts (exit detection, atomic save) can
  be tested without launching Chrome.
- **`slots.ps1`** — one PC, several people: each gets a container named `profile-<name>.enc` in the
  same folder. `Test-LPSlotName`, `Get-LPSlotPath`, `Get-LPSlots`, `Resolve-LPSlotChoice`,
  `Select-LPSlot`. Kept out of `profile-lib.ps1` because `change-password.ps1` needs slots but no
  Chrome code. Slots are a *file-naming* layer only — the container format, encryption, atomic save
  and backup are untouched by them, and the real boundary between people is still the password.
- **`log.ps1`** — off to the side of that stack, not a layer in it. `Start-LPLog` / `Stop-LPLog` wrap
  `Start-Transcript` so everything printed also lands in `run-log.txt` beside the scripts (i.e. on
  `D:`, which survives the shutdown wipe that erases `C:`). Both interactive entry points call
  `Start-LPLog` before their first output and `Stop-LPLog` in a `finally`. It never throws — if the
  transcript can't be opened it prints a note and returns `$false`, because a missing log must not
  stop Chrome from opening. Passwords cannot reach it: `Read-Host -AsSecureString` doesn't echo, so
  there is nothing for the transcript to capture. Keep it that way — never print a password, and
  never echo one for "confirmation".
- **`lab-profile.ps1`** — thin front end: guard, pick slot, prompt, open, launch, wait, save, wipe.
  Branches on whether the chosen container exists (setup mode vs normal mode). `change-password.ps1`
  and `collect-env.ps1` are siblings, and `unblock.ps1` is a fourth: a one-shot `Unblock-File` sweep
  of the folder, run once after copying to `D:`, because a GitHub ZIP leaves `Zone.Identifier` on
  every file and Windows then shows a warning dialog *before* `powershell.exe` starts — nothing our
  code can catch or log. `collect-env.ps1` records `BlockedFiles` so a recurrence proves the cause
  is AV/policy instead, which is an administrator's exception to grant, not a thing to code around.
  The `.bat` files are `-ExecutionPolicy Bypass` launchers using `%~dp0` (and pass `%*` through, so
  `start.bat hong` skips the menu) so the folder can be moved to `D:` intact. Each appends stderr to
  `boot-error.txt` and deletes it again when it is empty, so its mere existence means PowerShell
  died before `Start-LPLog` — the one window `run-log.txt` cannot cover.

Container format (`LP_HeaderSize` = 44):

```
"LABPROF1"(8B) | iterations(4B, LE) | salt(16B) | iv(16B) | ciphertext | HMAC-SHA256(32B)
```

`Protect-LPFile` computes that MAC **while writing**, by layering
`CryptoStream($file, $hmac, Write)` under the encrypting `CryptoStream` (a `HashAlgorithm` is an
`ICryptoTransform` whose `TransformBlock` copies input to output, so it tees). Do not "simplify" it
back to writing the file and then re-reading it to hash — that computed the MAC from *bytes read
back off disk*, so a byte corrupted during the write got a MAC stamped over it and the immediately
following `Test-LPContainer` passed too (same bad byte, same MAC). Binding the MAC to the bytes we
produced is what makes that verification a real round-trip check; it also removes one full read of
the container per save. `$hmac.Hash` is only populated after `FlushFinalBlock`, i.e. after the
streams are disposed — read it after, never before.

## Constraints that will bite you

**Target runtime is Windows PowerShell 5.1 / .NET Framework 4.8** on a lab PC where PowerShell 7
cannot be assumed. Verified absent: `AesGcm`, `CryptographicOperations.FixedTimeEquals`. Hence
AES-256-CBC + HMAC-SHA256 (encrypt-then-MAC) and the hand-rolled constant-time
`Test-LPBytesEqual`. Also unavailable: `??`, `?.`, ternary, `ConvertFrom-Json -AsHashtable`.

**`.ps1` files must be UTF-8 with BOM and CRLF.** PowerShell 5.1 reads BOM-less files as system
ANSI (CP949 on Korean Windows) and every Korean string becomes mojibake. If you create or fully
rewrite a `.ps1`, re-apply both:

```bash
printf '\xEF\xBB\xBF' > .bom.tmp && cat file.ps1 >> .bom.tmp && mv .bom.tmp file.ps1
perl -pi -e 's/\r?\n$/\r\n/' file.ps1
```

**`.bat` files must be pure ASCII — including `rem` comments.** Korean (UTF-8 multibyte) bytes in a
`.bat` do not merely print as mojibake on a CP949 console: `cmd.exe` mis-tracks its read offset and
**swallows the following line.** Measured: a file whose `echo 한글출력테스트` was followed by
`exit /b 7` printed both on one line and returned exit code 0. So every Korean string lives in a
`.ps1` (UTF-8 BOM, which PS 5.1 reads correctly) and the `.bat` stays a thin launcher — that is why
`unblock.bat` exists as a launcher for `unblock.ps1` rather than a single `-Command` one-liner.

**`Rfc2898DeriveBytes` defaults to SHA1.** Always pass
`[Security.Cryptography.HashAlgorithmName]::SHA256` explicitly.

**Wrong password returns `$false`; it does not throw.** `Unprotect-LPFile`,
`Unprotect-Container`, `Test-LPContainer`, and `Convert-ContainerPassword` all use this convention;
`throw` is reserved for corruption and programmer error. `lab-profile.ps1` depends on it to keep two
failures visibly distinct for the user — "container password wrong" (Chrome never launches) vs
"container opened fine, Google session expired" (login screen appears). That distinction is a
product requirement documented in `README.md`; do not collapse it into one message.

**Derive keys once per session.** PBKDF2 at 400,000 iterations costs ~1.7s. The open path derives a
`KeySet` and the save path reuses it — same salt, fresh IV. Never re-derive to save.
`Convert-ContainerPassword` is the one place that intentionally generates a new salt.

**Do not lower `LP_Iterations` to make the open path faster.** It is 1.8s of a ~31s session (6%), so
halving it buys 0.9s and halves the offline brute-force cost of a container copied off the shared
`D:`. The 12-character minimum-password guidance was removed on request (2026-09-11), so short
passwords can now actually arrive and the iteration count is the only remaining defense against
them. The count lives in the header, so a future change stays backward-compatible — that makes it
reversible, not a reason to do it.

**The work dir is shared, so guard it before prompting.** `%LOCALAPPDATA%\Temp\lp` is used by
whoever runs the script, so `lab-profile.ps1` does three things *before* slot selection and the
password prompt, in this order: refuse to start if `Get-LPChromeCount` sees a live session (starting
would corrupt the profile someone else has open), then delete any leftover work dir, aborting rather
than launching if that fails, then `Remove-LPStaleStaging` to sweep `%TEMP%\lp-<guid>.zip` left by a
crash — the same plaintext profile in another shape, so sweeping only the folder does not deliver
the guarantee `README.md` states. That third one warns and continues instead of aborting (a leftover
zip is not something the new session would start *on top of*); it lives in `crypto.ps1` next to
`New-LPTempPath`, which creates those files, because `change-password.ps1` needs it and
deliberately does not source `profile-lib.ps1`. Deferring the cleanup until after a successful
decrypt would leave the previous person's plaintext profile sitting there for anyone who mistypes a
password and quits.

**An unknown slot name from the CLI must be confirmed.** `Resolve-LPSlotChoice` deliberately treats
a name that isn't in the list as `Invalid`, not `New`. The `start.bat <name>` path bypasses that, and
`README.md` recommends that form, so `lab-profile.ps1` calls `Confirm-LPNewSlot` (default: refuse)
when the container is missing *and* other slots exist. Without it one typo silently starts a
fresh-setup session and the user thinks their profile is gone.

**`Get-LPSlots` emits its results one by one**, so callers must wrap: `@(Get-LPSlots -Root $x)`.
Returning `,$array` instead would nest when a caller wraps. Slot names are validated twice — at input
by `Test-LPSlotName` and again in `Get-LPSlotPath`, which throws; that second check is the last line
of defense against path traversal, so keep it loud.

**Never touch the live container before the new one verifies.** `Save-LPContainer` writes
`.tmp`, runs `Test-LPContainer` on it, then rotates live -> `.bak` -> and `.tmp` -> live. The
invariant is that a crash or a bad write costs at most one session's changes, never the login state.
`change-password.ps1` repeats the same sequence.

**Chrome exit detection cannot use the `Start-Process` PID.** Chrome's first process can exit while
children persist, and re-zipping while files are locked fails. `Get-LPChromeCount` polls
`Win32_Process` for `chrome.exe` whose `CommandLine` contains the `--user-data-dir` marker, using
`.Contains()` rather than `-like` (a path with `[` or `]` would be read as a wildcard).
`Wait-LPChromeExit` returns `$false` when no process ever appeared, and callers must then skip
saving.

**`LP_CacheDirs` in `profile-lib.ps1` is a denylist.** Adding a path that carries login state
silently breaks the whole point. The paths that must never appear there: `Local State`,
`Default\Preferences`, `Default\Network\Cookies`, `Default\Local Storage`,
`Default\Session Storage`, `Default\IndexedDB`.

## The gating dependency

Chrome cookies are wrapped in the current Windows user's DPAPI master key. If the lab PC assigns a
new SID / DPAPI key each boot, Chrome silently regenerates the key and discards the cookies, and
this entire design is worthless. `collect-env.ps1` exists to measure that empirically — run it,
reboot, run it again, compare `SID` and `UserDpapiKeys` in `env-log.txt`. Snapshot-restore labs pass;
profile-regeneration labs do not, and `README.md` documents the fallbacks (KeePassXC + TOTP, FIDO2
key). Do not build features that assume the answer.

**Measured 2026-09-09 on `PC09-13`** (Windows 11 Education, Chrome 138.0.7204.50, PS 5.1.26100.4202):
`SID` and `UserDpapiKeys` identical across a reboot, and a full shutdown followed by `start.bat`
reopened Chrome still logged into Google. That PC is snapshot-restore, so the design holds there.
This is one machine, not a property of the lab — any other seat or PC has to be measured the same
way before relying on it (`CHECKLIST.md` ends with that instruction).

**`PC18-18` (2026-09-10) is NOT measured.** The 2nd lab test ran there — four `start.bat` runs
inside four minutes, containers opened and saved fine — but there was **no reboot between them and
no `env-log.txt`**, so nothing about that PC's SID/DPAPI persistence was tested. Containers opening
within one uninterrupted session is not evidence; the key never had a chance to change. Treat
PC18-18 as unmeasured.

Chrome 127+ also adds App-Bound Encryption (`app_bound_encrypted_key`, `v20` cookies), validated by
the Elevation Service against the *calling binary's* path — not the profile path — so relocating the
profile to a `C:` temp dir is fine.
