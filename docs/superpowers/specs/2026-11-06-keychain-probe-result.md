# Keychain probe: moving the clipboard key to `local.utilitumus.app.clipboard`

Measured 2026-11-06 on macOS 26.2 (Darwin 25.2.0). Throwaway items only, service `local.utilitumus.test.keyprobe`, login keychain. The real item was never queried. Probe sources, binaries and logs: `scratchpad/probe-keychain` (`kp.swift`, `build.sh`, `log-run3.txt`).

## 1. Incident caused by this probe

The probe broke two of the brief's rules in effect, and the machine was left in a changed state.

- **A system dialog appeared.** At 21:59:36 an attribute-only `SecItemUpdate` from a rebuilt identity opened a SecurityAgent window, although the call had `kSecUseAuthenticationUIFail` and the process had `SecKeychainSetUserInteractionAllowed(false)`. The securityd log says `asking user about XARA partition for 'cdhash:6e13dd30…'`, which is that test build. Nothing was clicked.
- **securityd aborted, and the login keychain locked.** The call hung, so I killed the probe with `pkill` after about 3 minutes. securityd aborted at 22:02:34 (`SIGABRT`, uncaught C++ exception, `/Library/Logs/DiagnosticReports/securityd-2026-11-06-220237.ips`), and launchd respawned it. Its restart locked the keychains. The timing matches my kill to the second, but the stack is unsymbolicated, so the cause is very likely rather than proven.
- **Effect on the user.** Other apps needing the keychain asked SecurityAgent for an unlock: 15 new agent connections were logged between 22:02:35 and 22:03:51. I did not and could not unlock it, because that needs the user's password.
- **What it did not touch.** The real item was not read or changed by the probe. The only writes were test items.

Lessons for production code are in section 7.

## 2. Identities

All are `.app` bundles. A, B and D are signed with «Utilitumus Signing» and hardened runtime, like release builds. Identifiers are `local.utilitumus.test.<x>`.

| Name | Identifier | Signature | Purpose |
|---|---|---|---|
| A | `.a` | cert, runtime | item creator |
| A2 | `.a` | cert, runtime, new code | rebuild of A |
| Acopy | `.a` | same bytes as A | copy at another path |
| Eold | `.a` | cert, **no runtime** | old unhardened copy of A |
| Espoof | `.a` | **ad-hoc** | spoofs A's identifier |
| B | `.b` | cert, runtime | stands for the clipboard utility |
| B2 | `.b` | cert, runtime, new code | rebuild of B |
| Fold | `.b` | cert, **no runtime** | unhardened copy of B |
| C | `.c` | **ad-hoc** | unrelated identity |
| D | `.d` | cert, runtime | same cert, other bundle id |

Every status below was taken with both `kSecUseAuthenticationUIFail` in the query and `SecKeychainSetUserInteractionAllowed(false)` in the process. That flag is process-local: a fresh process still reports `true`.

## 3. Q1: B reads an item created by A

| Query by B, D, C, Eold, Espoof, A2 on A's item | Status |
|---|---|
| `kSecReturnData`, limit one (the production query) | **-25293** `errSecAuthFailed` |
| `kSecReturnAttributes`, limit one | **0**, no secret returned |
| `kSecReturnData`, `kSecMatchLimitAll` | -50 `errSecParam` |
| `kSecUseDataProtectionKeychain` = true | **-25300** `errSecItemNotFound` (measured for B) |
| `SecItemAdd` with the same service and account | -25299 `errSecDuplicateItem` (measured for B) |

**Does a denial ever return `errSecItemNotFound`?** Not with the production query: every denial was -25293. -25300 appeared only when the item was really absent, or when the query named the data protection keychain. So the data protection flag must stay out of the query, because on an existing key it reads as "no key". -25308 `errSecInteractionNotAllowed` was never seen, so code must not special-case it as the only denial.

**Locked keychain**, measured by accident after the incident:

| Operation while locked | Status |
|---|---|
| Read of an existing item | -25293 |
| `SecItemAdd` | -25293 |
| Read of an absent item | -25300 |
| Attributes-only list of the service | 0 |

So -25300 stayed trustworthy while locked.

**Limits.** The planned 40-read repeat is void, because its item was never created after the lock. The -25293 result rests on single reads per identity plus the repeats in the logs. `kSecUseAuthenticationUIFail` **alone was not run** (section 8).

**Foreign writes on A's item**, no dialog:

| Operation | Identity | Status | Result |
|---|---|---|---|
| `SecItemUpdate` of the value | B, ad-hoc C | **0** | Value replaced, partition list becomes the writer's cdhash. A then gets -25293 and so does the writer. |
| `SecItemUpdate` of the value | A2 | 0 | A2 can read its new value. A gets -25293. Old value gone. |
| `SecItemDelete` | B, C, A2 | -25244 `errSecInvalidOwnerEdit` | Item stays. |
| `SecItemDelete` | A (creating build) | 0 | Works, even on an item bricked by someone else. |

## 4. Q2: default ACL and rebuilds

ACL of an item made by A with the production `SecItemAdd`, read through `SecKeychainItemCopyAccess`:

| Authorizations | Who |
|---|---|
| Decrypt, Derive, ExportClear, ExportWrapped, MAC, Sign | A, `identifier "local.utilitumus.test.a" and certificate leaf = H"31e93f4b…"` |
| Encrypt | any application |
| Integrity | any application (description holds a hash) |
| **PartitionID** | `{Partitions = ("cdhash:64eb9fe6…")}`, the exact creating build |
| ChangeACL | empty list: nobody without a prompt |

The Decrypt entry does match by designated requirement. **The partition list decides, and without a Team ID it pins the exact build.**

| After a rebuild | Status |
|---|---|
| A2 at the same path (same identifier, same cert, new code) | **-25293** |
| A2 at another path | -25293 |
| Acopy, same bytes at another path | 0 |
| Original A again after restoring it | 0 |
| A2 `SecItemDelete` | -25244 |

The securityd log records `ACL partition mismatch: client cdhash:… ACL (cdhash:…)`. Apple's source agrees: `securityd/src/clientid.cpp:187-286` gives `teamid:` only to Apple-anchored certificates and `cdhash:` to any other signed code. The Apple source is from the public repository, so it may not match 26.2 exactly. The measurements do match it.

**Consequence for the real product (inferred, not measured on the real item):** any new hub build gets a partition prompt on its first read of the key, unless that exact build is already listed. This includes the build that would carry the migration code.

## 5. Q3: migration options

| Reader of the result | (a) ACL with A+B | (a') ACL + explicit partition list | (a'') decrypt = any app (**unacceptable**) | (b) B's own item | (c) add B to ACL |
|---|---|---|---|---|---|
| Created without UI? | yes, add = 0 | yes, add = 0 | yes, add = 0 | not measured | not run |
| A | 0 | 0 | 0 | - | - |
| **B** | **-25293** | **-25293** | -25293 | - | - |
| C ad-hoc | -25293 | -25293 | -25293 | - | - |
| D same cert | -25293 | -25293 | -25293 | - | - |
| Eold | -25293 | -25293 | -25293 | - | - |
| Fold | -25293 | -25293 | -25293 | - | - |
| A2 | -25293 | -25293 | -25293 | - | - |
| B2 | -25293 | -25293 | -25293 | - | - |

- **(a) fails.** The ACL lists both A and B, but securityd adds `cdhash:A` as the partition, so B is denied.
- **(a') fails.** The result holds two partition entries, `[A, B]` and securityd's own `[A]`, and B is still denied.
- **(a'') is unacceptable and also does not work.** It sets an any-application ACL. Only the partition list held the item, which is exactly why it must not be relied on. It was tested to see the exposure and is not an option.
- **(c) was not run.** After the incident I would not call `SecKeychainItemSetAccess`: the ChangeACL entry is an empty list, and the guards had just failed to stop a dialog on the update path. It is untested. Source (`acls.cpp:90-95`) shows that changing PARTITION_ID needs credentials that protect the database, meaning the keychain password, and `SecKeychainItemSetAccessWithPassword` is the public route for that. Adding B to the ACL alone could not help, as (a) shows.

**(b) measured so far**

| Step | Status |
|---|---|
| A reads the source | 0 |
| B `SecItemAdd` under the old service and account | -25299, so B's item needs a new name |
| B delete of A's item | -25244, so only A can remove the old item |
| A delete of its own item | 0 |

**(b) end to end was not measured.** The run started after the keychain had locked, so B's `SecItemAdd` returned -25293 and no item was created. The transport was only ever a pipe standing in for XPC. Its expected behaviour comes from A's own item, which uses the same code path: created with no UI, readable by its creator, -25293 for C, D, the unhardened copy and the rebuild. To finish it, run `run3.sh` once the login keychain is unlocked.

## 6. Recommendation

**(b): A hands the key to B once over the signed link, B creates its own item under a new name.** It is the only option left where B should end up able to read without the keychain password: (a) measurably fails and (c) needs the password by source. It does not touch the old item's ACL and it widens nobody's access. This rests on A's item as the analogue, because B's own item was not measured (section 5).

Rules:

1. New name: service `local.utilitumus.app.clipboard`, account `history-key`. The old name returns -25299 for B while the old item exists.
2. B's order on start:
   - Read own item. 0: use it, after checking that it decrypts the index.
   - -25300 on own item: query the **old item with `kSecReturnAttributes` only**. It returns 0 without a secret, and that means "key exists, must migrate". Ask A over the link.
   - Old item absent too, and no `index.bin`: first run, create a new key.
   - Old item absent too, but `index.bin` exists: stop and show an error. Do not create a key.
   - Any other status, including -25293: stop and show an error. Do not create a key, and do not set the index aside.
3. Receiving: B checks the length is 32 and that the key decrypts `index.bin` **before** adding its item. If it does not decrypt, B refuses and adds nothing. This also covers a fake key from an old copy posing as the sender.
4. After adding: B reads its item back, compares, decrypts the index again, and only then sends the confirmation.
5. Only A deletes the old item, and only after B's confirmation. B cannot (-25244). A crash anywhere before that leaves the old item intact, and the next start repeats the flow. A leftover own item that fails to decrypt may be deleted by B, then the handover repeats.
6. A sends only to a peer passing `identifier "local.utilitumus.app.clipboard" and certificate leaf = H"31e93f4b…"`.
7. Remove `delete()` before `add` from any path still based on `main`: on `main`, `key()` deletes on any failed read. The hub branch is already correct here.

**Prompts remain in two places, and no migration removes them:**

- **The hub build carrying the migration** is a new cdhash, so its first read of the old item needs the user's approval. Inferred from section 4. A no-prompt migration of the real item is not possible unless that exact build is already listed. Run the read off the main thread (survey gap 4).
- **Every update of B** hits the same partition check on B's own item.

Decision needed for the second one, neither measured:

- Developer ID certificate: `teamid:` partition, stable across builds (source only). Costs a paid account, and the pinned certificate hash changes in `Updater` and `install.sh`.
- A small frozen helper binary that holds the key, with a cdhash that never changes across releases. It must verify its caller's signature, or anyone could run it. Only the same-bytes half is measured (Acopy reads).

## 7. Q4: the same-cert risk, plainly

- **The certificate alone gives no silent read.** D (same cert, other id), Eold (same cert, same id, unhardened), Fold, A2 and B2 all got -25293. The partition list, not the cert, is what holds them off.
- **An exact copy of a listed build reads silently** (Acopy = 0). So any old unhardened hub build whose cdhash is on the real item's partition list reads the **old** item with no prompt, and it accepts `DYLD_INSERT_LIBRARIES`. I could not check the real list, by rule. This is the reason to delete the old item after handover.
- **Any same-cert or other app can ask.** Denied builds get a prompt when UI is allowed, so a user who types the password grants them access (`acls.cpp:181`, not triggered).
- **The link is weaker than the keychain.** It matches by requirement, so any binary with B's identifier signed by this cert gets the key from A. That needs the private key. B must never ship unhardened, so no injectable copy with its identifier exists.
- **Integrity is not protected at all.** Any process of this user, no cert needed, can destroy the key without a prompt through `SecItemUpdate` (ad-hoc C = 0). It reads nothing, but history is lost. A decrypt failure must never be treated as "new key", and an overwritten value then approved by a prompt would be an attacker-chosen key.

**For production code:**

- Never use attribute-only `SecItemUpdate` on this item: it ignored both guards and opened a dialog.
- `kSecUseAuthenticationUIFail` is not referenced in the legacy path of `SecItem.cpp`. Do not rely on it alone for a non-prompting read: use `SecKeychainSetUserInteractionAllowed(false)`, which is process-wide.
- A prompt that blocks a call cannot be safely ended by killing the process, as far as this incident shows.

## 8. Untested

- (c), in any form.
- `kSecUseAuthenticationUIFail` alone on a denied read. Source suggests it is ignored here, so running it risked a dialog.
- What any prompt looks like, and "Always Allow" adding a partition entry (source only).
- The real item, and the real XPC link for this payload (see `2026-11-06-link-probe-result.md`).
- Developer ID and the frozen helper.

## 9. Cleanup state: NOT DONE

The login keychain was still locked when this report was written (22:07), and I can't unlock it. These test items remain, all under `local.utilitumus.test.keyprobe`, confirmed by an attributes-only list of that service: `a1 a2 s1 t1 t2 t4 t5 t6 x1`.

Once the login keychain is unlocked, run `scratchpad/probe-keychain/cleanup.sh`. It deletes each item through the build that owns it, which earlier returned 0 even on a bricked item, then lists what is left. It refuses to run while locked. Do not rebuild `bin/A.app` or `bin/GA.app` first: other builds get -25244 on delete.
