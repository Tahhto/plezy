import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../media/library_change_event.dart';
import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../../media/media_server_client.dart';
import '../../utils/app_logger.dart';
import '../../utils/external_ids.dart';
import '../../utils/library_content_notifier.dart';

/// In-memory map from external ids (IMDb / TMDB / TVDB) to the user's library
/// items, one sweep per server ([MediaServerClient.fetchExternalIdIndex]).
///
/// Custom Home sections resolve every list entry against it locally, so a
/// 250-entry IMDb chart costs one paged sweep per server instead of 250
/// reverse lookups. A server's index is rebuilt after [ttl], and dropped as
/// soon as that server pushes a library change, so newly added media shows up
/// on the next Home refresh.
class LibraryExternalIdIndex {
  LibraryExternalIdIndex({
    required MediaServerClient? Function(String serverId) clientFor,
    this.ttl = const Duration(minutes: 30),
    DateTime Function()? now,
    Stream<LibraryChangeEvent>? libraryEvents,
    // A private field cannot be a named initializing formal callers can pass.
    // ignore: prefer_initializing_formals
  }) : _clientFor = clientFor,
       _now = now ?? DateTime.now {
    _libraryEventSubscription = (libraryEvents ?? LibraryContentNotifier().stream).listen(_onLibraryChanged);
  }

  final MediaServerClient? Function(String serverId) _clientFor;
  final Duration ttl;
  final DateTime Function() _now;
  StreamSubscription<LibraryChangeEvent>? _libraryEventSubscription;

  final Map<String, _ServerIndex> _byServer = {};
  final Map<String, Future<void>> _inFlight = {};

  void _onLibraryChanged(LibraryChangeEvent event) {
    if (!event.hasChanges) return;
    _byServer.remove(event.serverId.value);
  }

  /// Drop every server's index; the next [ensureLoaded] rebuilds them.
  void invalidate() => _byServer.clear();

  /// Build (or rebuild once stale) the index of each of [serverIds].
  /// Concurrent calls for one server share a single sweep. A server whose
  /// sweep fails keeps its previous index, if any, and is logged — one
  /// unreachable server must not blank the others' rows.
  Future<void> ensureLoaded(Iterable<String> serverIds) async {
    await Future.wait([for (final serverId in serverIds) _ensureServer(serverId)]);
  }

  Future<void> _ensureServer(String serverId) {
    final existing = _byServer[serverId];
    if (existing != null && _now().difference(existing.builtAt) < ttl) return Future<void>.value();
    // Block body: an arrow would return the removed future — this very one —
    // and `whenComplete` would then wait on itself forever.
    return _inFlight[serverId] ??= _build(serverId).whenComplete(() {
      _inFlight.remove(serverId);
    });
  }

  Future<void> _build(String serverId) async {
    final client = _clientFor(serverId);
    if (client == null) return;
    try {
      final entries = await client.fetchExternalIdIndex();
      _byServer[serverId] = _ServerIndex.build(entries, builtAt: _now());
      appLogger.d('LibraryExternalIdIndex: indexed ${entries.length} items on $serverId');
    } catch (error, stackTrace) {
      appLogger.w('LibraryExternalIdIndex: sweep failed on $serverId', error: error, stackTrace: stackTrace);
    }
  }

  /// Library copies of the title [ids] names, across every indexed server in
  /// [serverIds] order. [kind] scopes the TMDB id, which TMDB reuses between
  /// its movie and TV namespaces; null (an IMDb chart entry of unknown type)
  /// matches by IMDb id only, which is unique across types.
  List<MediaItem> lookup(ExternalIds ids, {MediaKind? kind, required Iterable<String> serverIds}) {
    final results = <MediaItem>[];
    for (final serverId in serverIds) {
      final index = _byServer[serverId];
      if (index == null) continue;
      results.addAll(index.lookup(ids, kind: kind));
    }
    return results;
  }

  @visibleForTesting
  bool hasIndexFor(String serverId) => _byServer.containsKey(serverId);

  void dispose() {
    unawaited(_libraryEventSubscription?.cancel());
    _libraryEventSubscription = null;
  }
}

class _ServerIndex {
  _ServerIndex._(this.builtAt);

  final DateTime builtAt;
  final Map<String, List<MediaItem>> _byKey = {};

  factory _ServerIndex.build(List<ExternalIdIndexEntry> entries, {required DateTime builtAt}) {
    final index = _ServerIndex._(builtAt);
    for (final entry in entries) {
      final kind = entry.item.kind;
      for (final key in externalIdIndexKeys(entry.ids, kind: kind)) {
        (index._byKey[key] ??= []).add(entry.item);
      }
    }
    return index;
  }

  List<MediaItem> lookup(ExternalIds ids, {MediaKind? kind}) {
    final seen = <String>{};
    return [
      for (final key in externalIdIndexKeys(ids, kind: kind))
        for (final item in _byKey[key] ?? const <MediaItem>[])
          if (seen.add(item.id)) item,
    ];
  }
}

/// The index keys an item with [ids] is filed (and looked up) under. TMDB and
/// TVDB ids are namespaced by [kind] because both reuse numbers across their
/// movie and series tables; with no kind only the IMDb id is usable.
@visibleForTesting
List<String> externalIdIndexKeys(ExternalIds ids, {MediaKind? kind}) {
  final kindKey = switch (kind) {
    MediaKind.movie => 'movie',
    MediaKind.show => 'show',
    _ => null,
  };
  return [
    if (ids.imdb case final imdb?) 'imdb:${imdb.toLowerCase()}',
    if (kindKey != null) ...[
      if (ids.tmdb case final tmdb?) 'tmdb:$kindKey:$tmdb',
      if (ids.tvdb case final tvdb?) 'tvdb:$kindKey:$tvdb',
    ],
  ];
}
