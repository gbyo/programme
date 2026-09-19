# Managed configuration (MDM)

Programme reads an optional [ManagedApp](https://developer.apple.com/documentation/managedapp)
app configuration delivered by MDM. Everything here is optional: an unmanaged
device behaves exactly as before, and MDM is never required for scoring,
recovery, export, or any local feature.

Deploy the payload as the managed app configuration dictionary for
Programme's bundle ID. All keys are optional.

| Key | Plist type | Required | Valid values | Default | Suggestion or enforced policy |
| --- | --- | --- | --- | --- | --- |
| `suggestedTeamID` | String | No | UUID string of a team on the device | None | Suggestion: selected only when the device has no explicit user-chosen team. Never overrides a user selection. Unknown IDs are ignored. |
| `defaultRulesName` | String | No | `High School`, `High School (No Overtime)`, `College`, `Professional`, `Middle School`, `Youth (Quarters)` | `High School` | Suggestion: fallback for teams with no stored default. A stored user default always wins. |
| `defaultTrackingMode` | String | No | `ourTeam`, `bothTeams` | `ourTeam` | Suggestion: fallback for teams with no stored default. A stored user default always wins. |
| `allowCollaboration` | Boolean | No | `true` / `false` | `true` (allowed) | Enforced policy when `false`: no new team shares, no share surfaces, incoming invitations refused. See below. |
| `allowAutomatedRosterExtraction` | Boolean | No | `true` / `false` | `true` (allowed) | Enforced policy when `false`: camera scan, photo import and on-device-model roster interpretation are hidden. File, paste and manual entry always remain. |

Invalid values (unknown preset name, unknown tracking mode, malformed team
ID, mistyped policy) throw a validation error bridged to ManagedApp's
`ManagedAppConfigurationDecodingError`, so the failure is actionable in
managed-device consoles instead of silently ignored. Managed values are
never logged.

## Suggestions are never persisted as user choices

A suggestion only fills in where the user never chose: the stored per-team
default wins over `defaultRulesName` / `defaultTrackingMode`, and an
explicit team selection wins over `suggestedTeamID`. Opening Settings or New
Match, or creating a match without touching a field, never writes a managed
value into `UserDefaults` — managed fallbacks re-derive from the live
configuration on every load, so a later profile change still applies to
values the user never overrode. Bootstrap awaits the initial MDM value
(Apple documents it as yielding immediately) so the first automatic team
selection sees the suggestion.

## What `allowCollaboration = false` does

"Collaboration" means sharing with *other people*. It does not mean a
person's own cross-device sync:

- No new `CKShare` can be created; ShareLink and the system share surfaces
  cannot load (`teamShareItem` throws below the UI layer, not just in views).
- Incoming share invitations are refused; the invitation stays valid in
  CloudKit, so it can be accepted after the policy lifts.
- The owner's explicit Stop Sharing stays available: revoking access is
  safe under this policy.
- The user's own private-database CloudKit sync across their devices keeps
  running. Already-shared zones also keep syncing so shared truth stays
  converged and review-gated; no new participants can join.
- Local data is never modified or destroyed by this policy.
- Flipping the value while Programme runs applies immediately: share
  surfaces reload and invitation handling re-checks on every call.

Stop Sharing (owner) and leaving (participant, via Apple's system UI) never
delete local match truth.
