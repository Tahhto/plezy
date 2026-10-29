import 'dart:async';

import 'package:flutter/foundation.dart';

import '../media/ids.dart';
import '../media/media_hub.dart';
import '../media/media_item.dart';
import '../media/media_kind.dart';
import '../mixins/disposable_change_notifier_mixin.dart';
import '../models/home_sections/home_layout.dart';
import '../services/home_sections/home_list_fetcher.dart';
import '../services/home_sections/home_list_ref.dart';
import '../services/home_sections/library_external_id_index.dart';
import '../services/settings_service.dart';
import '../utils/app_logger.dart';
import 'hidden_libraries_provider.dart';
import 'multi_server_provider.dart';

/// Owns the user's Home layout (custom list sections, row order, hidden rows)
/// and resolves each custom section to a [MediaHub] of library items.
///
/// A section's list is fetched from its provider (cached for [listTtl]), then
/// every entry is matched by IMDb/TMDB/TVDB id against the
/// [LibraryExternalIdIndex] — no per-title server request. Only titles the
/// user can play appear; hidden libraries are respected.
///
/// Lives in the profile-keyed provider subtree next to `DiscoverProvider`,
/// whose built-in hubs the Discover screen merges with these through
/// [compose].
class HomeSectionsProvider extends ChangeNotifier with DisposableChangeNotifierMixin {
  HomeSectionsProvider(
    this._multiServer,
    this._hiddenLibraries,
    this._fetcher, {
    required this.profileId,
    LibraryExternalIdIndex? index,
    this.listTtl = const Duration(hours: 1),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now,
       _index =
           index ??
           LibraryExternalIdIndex(clientFor: (serverId) => _multiServer.getClientForServer(ServerId(serverId))) {
    _multiServer.addOnlineServersListener(_onOnlineServersChanged);
  }

  final MultiServerProvider _multiServer;
  final HiddenLibrariesProvider _hiddenLibraries;
  final HomeListFetcher _fetcher;
  final LibraryExternalIdIndex _index;
  final DateTime Function() _now;
  final String? profileId;

  /// How long a fetched list is reused before its provider is asked again.
  final Duration listTtl;

  /// Entries read per list. Rows only show titles the user owns, so reading
  /// past the row cap is what lets a long list still fill it.
  static const int _listFetchLimit = 300;

  HomeLayout _layout = HomeLayout.empty;
  bool _layoutLoaded = false;
  Map<String, MediaHub> _customHubs = const {};
  Map<String, String> _errors = const {};
  final Map<String, ({DateTime at, List<HomeListEntry> entries})> _listCache = {};
  Set<String> _resolvedServerIds = const {};

  Future<void>? _activeLoad;
  bool _reloadQueued = false;
  bool _forceQueued = false;

  HomeLayout get layout => _layout;
  bool get isLayoutLoaded => _layoutLoaded;

  /// Section id → resolved row; only sections with at least one owned title.
  Map<String, MediaHub> get customHubs => _customHubs;

  /// Section id → last fetch failure, for the settings screen.
  Map<String, String> get errors => _errors;

  bool get isLoading => _activeLoad != null;

  List<MediaHub>? _composeInput;
  Map<String, MediaHub>? _composeCustom;
  HomeLayout? _composeLayout;
  List<MediaHub> _composed = const [];

  /// [builtInHubs] arranged under the layout, with custom rows merged in.
  /// Memoized on input identity so rebuilds keep handing the screen the same
  /// list instance (the screen diffs hub lists by identity).
  List<MediaHub> compose(List<MediaHub> builtInHubs) {
    if (identical(builtInHubs, _composeInput) &&
        identical(_customHubs, _composeCustom) &&
        identical(_layout, _composeLayout)) {
      return _composed;
    }
    _composeInput = builtInHubs;
    _composeCustom = _customHubs;
    _composeLayout = _layout;
    _composed = _layout.isEmpty
        ? builtInHubs
        : composeHomeHubs(builtInHubs: builtInHubs, customHubs: _customHubs, layout: _layout);
    return _composed;
  }

  Future<void> _ensureLayoutLoaded() async {
    if (_layoutLoaded) return;
    final settings = await SettingsService.getInstance();
    if (isDisposed || _layoutLoaded) return;
    _layout = settings.read(SettingsService.homeLayoutPref(profileId));
    _layoutLoaded = true;
    safeNotifyListeners();
  }

  /// Persist [layout] and re-resolve the sections it names.
  Future<void> saveLayout(HomeLayout layout) async {
    final settings = await SettingsService.getInstance();
    if (isDisposed) return;
    await settings.write(SettingsService.homeLayoutPref(profileId), layout);
    _layout = layout;
    _layoutLoaded = true;
    // Drop rows of sections that no longer exist straight away.
    final ids = {for (final section in layout.sections) section.id};
    _customHubs = {
      for (final entry in _customHubs.entries)
        if (ids.contains(entry.key)) entry.key: entry.value,
    };
    safeNotifyListeners();
    unawaited(load());
  }

  /// Resolve every visible custom section. [force] refetches lists and
  /// rebuilds the library index (pull-to-refresh). Concurrent calls coalesce
  /// into the running pass plus at most one trailing pass.
  Future<void> load({bool force = false}) {
    if (isDisposed) return Future<void>.value();
    final active = _activeLoad;
    if (active != null) {
      _reloadQueued = true;
      _forceQueued |= force;
      return active;
    }
    late final Future<void> run;
    run = _runLoads(force).whenComplete(() {
      if (identical(_activeLoad, run)) _activeLoad = null;
      safeNotifyListeners();
    });
    _activeLoad = run;
    return run;
  }

  Future<void> _runLoads(bool force) async {
    var passForce = force;
    do {
      _reloadQueued = false;
      _forceQueued = false;
      await _loadOnce(force: passForce);
      passForce = _forceQueued;
    } while (_reloadQueued && !isDisposed);
  }

  Future<void> _loadOnce({required bool force}) async {
    await _ensureLayoutLoaded();
    if (isDisposed) return;
    final sections = [
      for (final section in _layout.sections)
        if (!_layout.hidden.contains(section.layoutKey)) section,
    ];
    if (sections.isEmpty) {
      if (_customHubs.isNotEmpty || _errors.isNotEmpty) {
        _customHubs = const {};
        _errors = const {};
        safeNotifyListeners();
      }
      return;
    }

    await _hiddenLibraries.ensureInitialized();
    final serverIds = _multiServer.onlineServerIds;
    if (force) {
      _index.invalidate();
      _listCache.clear();
    }
    await _index.ensureLoaded(serverIds);
    if (isDisposed) return;
    _resolvedServerIds = serverIds.toSet();

    final hubs = <String, MediaHub>{};
    final errors = <String, String>{};
    await Future.wait([
      for (final section in sections)
        _resolveSection(section, serverIds).then(
          (hub) {
            if (hub != null) hubs[section.id] = hub;
          },
          onError: (Object error, StackTrace stackTrace) {
            appLogger.w('HomeSections: "${section.title}" failed', error: error, stackTrace: stackTrace);
            errors[section.id] = error is HomeListFetchException ? error.message : '$error';
            // Keep the last good row rather than blanking it on a transient failure.
            final previous = _customHubs[section.id];
            if (previous != null) hubs[section.id] = previous;
          },
        ),
    ]);
    if (isDisposed) return;
    _customHubs = hubs;
    _errors = errors;
    safeNotifyListeners();
  }

  Future<List<HomeListEntry>> _entriesFor(HomeListRef ref) async {
    final key = '${ref.source.name}|${ref.path}|${ref.defaultKind?.name}';
    final cached = _listCache[key];
    if (cached != null && _now().difference(cached.at) < listTtl) return cached.entries;
    final entries = await _fetcher.fetch(ref, maxItems: _listFetchLimit);
    _listCache[key] = (at: _now(), entries: entries);
    return entries;
  }

  Future<MediaHub?> _resolveSection(CustomHomeSection section, List<String> serverIds) async {
    final ref = HomeListRef.tryParse(section.url);
    if (ref == null) throw FormatException('Unsupported list URL: ${section.url}');
    final entries = await _entriesFor(ref);
    final items = resolveHomeSectionItems(
      section: section,
      entries: entries,
      lookup: (entry) => _index.lookup(entry.ids, kind: entry.kind, serverIds: serverIds),
      hiddenLibraryKeys: _hiddenLibraries.hiddenLibraryKeys,
    );
    if (items.isEmpty) return null;
    final serverIdSet = {for (final item in items) item.serverId};
    return MediaHub(
      id: 'custom.${section.id}',
      identifier: 'custom.${section.id}',
      title: section.title,
      type: switch (section.kinds) {
        HomeSectionKindFilter.movies => 'movie',
        HomeSectionKindFilter.shows => 'show',
        HomeSectionKindFilter.all => 'mixed',
      },
      items: items,
      size: items.length,
      serverId: serverIdSet.length == 1 ? serverIdSet.single : null,
    );
  }

  /// Fetch [url] and report how many of its titles the user owns, for the
  /// section editor's "Test" button. Throws on an unsupported URL or a failed
  /// fetch.
  Future<({int listed, int owned})> preview(
    String url, {
    HomeSectionKindFilter kinds = HomeSectionKindFilter.all,
  }) async {
    final ref = HomeListRef.tryParse(url);
    if (ref == null) throw FormatException('Unsupported list URL: $url');
    final serverIds = _multiServer.onlineServerIds;
    await _hiddenLibraries.ensureInitialized();
    await _index.ensureLoaded(serverIds);
    final entries = await _entriesFor(ref);
    final owned = resolveHomeSectionItems(
      section: CustomHomeSection(id: '', title: '', url: url, kinds: kinds, maxItems: 1 << 30),
      entries: entries,
      lookup: (entry) => _index.lookup(entry.ids, kind: entry.kind, serverIds: serverIds),
      hiddenLibraryKeys: _hiddenLibraries.hiddenLibraryKeys,
    );
    return (listed: entries.length, owned: owned.length);
  }

  /// A server that came online after the last pass has no rows in the custom
  /// sections yet; re-resolve so its titles join.
  void _onOnlineServersChanged(Set<String> onlineServerIds) {
    if (isDisposed || !_layoutLoaded || _layout.sections.isEmpty) return;
    if (_resolvedServerIds.containsAll(onlineServerIds)) return;
    unawaited(load());
  }

  @override
  void dispose() {
    _multiServer.removeOnlineServersListener(_onOnlineServersChanged);
    _index.dispose();
    _fetcher.dispose();
    super.dispose();
  }
}

/// The library items a custom section shows, in list order.
///
/// Per entry: apply the section's kind filter, look up its library copies,
/// drop copies in hidden libraries (and of the wrong kind, when the list did
/// not say which kind the entry is), and keep the first remaining copy — the
/// lookup returns servers in priority order. Repeats and, with
/// [CustomHomeSection.hideWatched], watched titles are skipped. Stops at
/// [CustomHomeSection.maxItems].
@visibleForTesting
List<MediaItem> resolveHomeSectionItems({
  required CustomHomeSection section,
  required List<HomeListEntry> entries,
  required List<MediaItem> Function(HomeListEntry entry) lookup,
  required Set<String> hiddenLibraryKeys,
}) {
  final wanted = switch (section.kinds) {
    HomeSectionKindFilter.movies => const {MediaKind.movie},
    HomeSectionKindFilter.shows => const {MediaKind.show},
    HomeSectionKindFilter.all => const {MediaKind.movie, MediaKind.show},
  };
  final seen = <String>{};
  final items = <MediaItem>[];
  for (final entry in entries) {
    if (items.length >= section.maxItems) break;
    if (entry.kind != null && !wanted.contains(entry.kind)) continue;
    MediaItem? chosen;
    for (final copy in lookup(entry)) {
      if (!wanted.contains(copy.kind)) continue;
      final libraryKey = copy.libraryGlobalKey;
      if (libraryKey != null && hiddenLibraryKeys.contains(libraryKey)) continue;
      chosen = copy;
      break;
    }
    if (chosen == null || !seen.add(chosen.globalKey)) continue;
    if (section.hideWatched && chosen.isWatched) continue;
    items.add(chosen);
  }
  return items;
}
