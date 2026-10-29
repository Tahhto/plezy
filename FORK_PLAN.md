# Plezy fork plan: customizable Home sections

**Goal:** a Plezy fork (`Tahhto/plezy`) where the Home screen, when connected to Jellyfin, can be fully
customized: rows built from Trakt, MDBList and IMDb lists, plus reordering and hiding of every row.

**Working branch:** `feature/custom-home-sections`, based on upstream `edde746/plezy@ffe7d79`.

---

## Where things stand

### Done (commit `5fea2f3`)
| Area | Files |
|---|---|
| Server index of every movie/show with IMDb/TMDB/TVDB ids (Jellyfin + Plex) | `lib/media/media_server_client.dart` (`fetchExternalIdIndex`), `lib/services/jellyfin_client/parts/browse.dart`, `lib/services/plex_client.dart` |
| Cached per-server index (30 min TTL, dropped on library-change events) | `lib/services/home_sections/library_external_id_index.dart` |
| URL parsing (Trakt / MDBList / IMDb) | `lib/services/home_sections/home_list_ref.dart` |
| Response parsers | `lib/services/home_sections/home_list_parsers.dart` |
| Fetcher (uses Trakt login when present) | `lib/services/home_sections/home_list_fetcher.dart`, `TraktClient.getRaw` |
| Layout model, per-profile storage | `lib/models/home_sections/home_layout.dart`, `SettingsService.homeLayoutPref` |
| Provider (resolve lists to rows, 1 h list cache) | `lib/providers/home_sections_provider.dart`, registered in `lib/navigation/profile_session_screen.dart` |
| Home screen integration | `lib/screens/discover_screen.dart` (`_hubs` = composed rows) |
| Settings UI | `lib/screens/settings/home_sections_screen.dart`, entry in Appearance → Home Screen |
| Strings (English; other locales fall back) | `lib/i18n/en.i18n.json` → `homeSections.*`, `settings.homeSections*` |
| Tests (35) | `test/services/home_sections/`, `test/models/home_sections/`, `test/providers/home_sections_provider_test.dart` |

`flutter analyze lib test` is clean. All 35 new tests pass.

Full upstream suite (8,346 tests) and `scripts/checks/check_codegen.py` pass. DiscoverScreen treats
HomeSectionsProvider as optional, so screens built without a profile session (like the upstream widget tests) still work.

### Not yet verified
- Real responses from Trakt, MDBList and IMDb. The cloud container's network blocks those hosts, so the parsers
  are built from documented formats and tested only against hand-written sample responses.
- Running on a device. Nothing has been clicked through yet.

---

## Step-by-step plan

### Phase 0: Unblock pushing (needs you)
1. Install the Claude GitHub App on `Tahhto/plezy`: https://github.com/apps/claude/installations/select_target,
   or reconnect GitHub at claude.ai → Settings → Connectors.
2. Push `feature/custom-home-sections` to the fork. If this container has been reclaimed by then, apply the
   patch file `0001-Add-custom-Home-sections-from-Trakt-MDBList-and-IMDb.patch` with `git am`.

### Phase 1: Prove it works for real
3. Finish the full upstream test suite and the codegen check, and fix anything that broke.
4. Allow `api.trakt.tv`, `mdblist.com` and `www.imdb.com` in the cloud environment's network settings, or run
   the checks locally. Record one real response per source as a test fixture and correct the parsers wherever
   reality differs from the documented formats.
5. Build and run on your actual device (Android TV / Android / desktop: `flutter run`), connected to your
   Jellyfin server. Then check:
   - Adding a Trakt list, an MDBList list, IMDb Top 250 and an IMDb `ls…` list each produces a Home row.
   - Reordering and hiding built-in rows survives an app restart.
   - Hidden libraries stay hidden in custom rows.
   - The toolbar refresh refetches lists; adding media to Jellyfin shows up in a matching row.
   - Every screen can be operated with the D-pad.
6. Note how long the first library sweep takes on a large library (log line `LibraryExternalIdIndex: indexed N
   items`). If it's slow, lower the page size or sweep in the background after Home renders.

### Phase 2: Close the obvious gaps
7. **"See all" for custom rows:** set `more: true` when the list has more owned titles than the row cap, and
   route Hub detail to a grid of every owned title in the list.
8. **Watch-state updates in custom rows:** reuse DiscoverProvider's watch/deletion event patching so marking
   something watched updates the row without a refresh.
9. **Loading/error feedback:** show a spinner on the settings screen while lists load, and a small error marker
   on a Home row whose list failed (currently only shown in settings).
10. **IMDb lists over 250 titles:** fetch `?page=2…` until the cap.
11. **MDBList fallback:** if the public JSON export fails and an MDBList account is connected, use the API via
    `MdblistClient`.
12. **Clear Trakt errors:** for a private list, tell the user to sign in to Trakt (Settings → Services) instead
    of showing a bare 401/404.

### Phase 3: Nice-to-haves (pick what you want)
13. One-tap presets (IMDb Top 250, Trakt Trending Movies/Shows, …) in the Add dialog.
14. Jellyfin collections and playlists as Home rows (no external list needed).
15. Per-row card style: poster vs landscape.
16. The deferred option: show titles you don't own as greyed cards, with Seerr request support.
17. Sync the layout across devices (store it in Jellyfin `DisplayPreferences` custom prefs instead of local
    settings).
18. Translations for the new strings.

### Phase 4: Ship and maintain
19. Enable GitHub Actions on the fork (upstream workflows) so analyze, tests and codegen run on every push.
20. Produce release builds (APK for Android/TV first).
21. Keep the fork current: periodically `git fetch upstream && git rebase upstream/main` on the feature branch.
22. Optional: open a PR upstream. CONTRIBUTING.md requires naming the AI model(s) used in the PR description.
23. License: Plezy is GPL-3.0, so any builds you distribute must ship with source under GPL-3.0.

---

## To do next (after compacting the session)
1. ~~Check the full test suite and codegen.~~ Done: both pass.
2. Once GitHub access is fixed, run `git push -u fork feature/custom-home-sections` from
   `/home/user/edde746/plezy` (remote `fork` = `https://github.com/Tahhto/plezy`).
3. Phase 1, step 4: capture real Trakt / MDBList / IMDb responses and turn them into fixture tests.
4. Hand off the device test checklist (Phase 1, step 5) to the user and wait for feedback.
5. Start Phase 2 with step 7 ("See all") and step 9 (loading/error feedback), the two most visible gaps.

Environment notes: the Flutter SDK is at `/home/user/flutter-sdk/bin` (add it to `PATH`). Use `dart format -l 120`.
Baseline `flutter analyze` (whole repo) has 49 pre-existing issues, all in vendored `packages/` tests.
