import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/library_change_event.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/models/home_sections/home_layout.dart';
import 'package:plezy/providers/home_sections_provider.dart';
import 'package:plezy/services/home_sections/home_list_ref.dart';
import 'package:plezy/services/home_sections/library_external_id_index.dart';
import 'package:plezy/utils/external_ids.dart';
import 'package:plezy/utils/media_server_http_client.dart' show AbortController;

import '../test_helpers/media_items.dart';

MediaItem _item(
  String id, {
  MediaKind kind = MediaKind.movie,
  String serverId = 's1',
  String libraryId = 'lib1',
  int? viewCount,
}) => testMediaItem(id: id, kind: kind, title: id, serverId: serverId, libraryId: libraryId, viewCount: viewCount);

class _IndexClient implements MediaServerClient {
  _IndexClient(this.entries);

  List<ExternalIdIndexEntry> entries;
  int sweeps = 0;

  @override
  Future<List<ExternalIdIndexEntry>> fetchExternalIdIndex({AbortController? abort}) async {
    sweeps++;
    return entries;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('resolveHomeSectionItems', () {
    const section = CustomHomeSection(id: 'x', title: 'X', url: 'u', maxItems: 3);
    final matrix = _item('matrix');
    final matrixHidden = _item('matrix-hidden-copy', libraryId: 'hiddenLib');
    final bb = _item('bb', kind: MediaKind.show);
    final watched = _item('watched', viewCount: 1);

    final byImdb = <String, List<MediaItem>>{
      'tt1': [matrixHidden, matrix],
      'tt2': [bb],
      'tt3': [watched],
      'tt4': [_item('four')],
      'tt5': [_item('five')],
    };
    List<MediaItem> lookup(HomeListEntry entry) => byImdb[entry.ids.imdb] ?? const [];
    HomeListEntry entry(String imdb, [MediaKind? kind]) => HomeListEntry(
      kind: kind,
      ids: ExternalIds(imdb: imdb),
    );

    test('keeps list order, skips hidden-library copies, repeats and missing titles, and caps', () {
      final items = resolveHomeSectionItems(
        section: section,
        entries: [entry('tt0'), entry('tt1'), entry('tt1'), entry('tt2'), entry('tt4'), entry('tt5')],
        lookup: lookup,
        hiddenLibraryKeys: {matrixHidden.libraryGlobalKey!},
      );
      expect(items.map((i) => i.id), ['matrix', 'bb', 'four']);
    });

    test('kind filter applies to list kind and, for untyped entries, to the copy', () {
      final items = resolveHomeSectionItems(
        section: section.copyWith(kinds: HomeSectionKindFilter.movies),
        entries: [entry('tt2'), entry('tt2', MediaKind.show), entry('tt1', MediaKind.movie)],
        lookup: lookup,
        hiddenLibraryKeys: const {},
      );
      expect(items.map((i) => i.id), ['matrix-hidden-copy']);
    });

    test('hideWatched drops watched titles', () {
      final items = resolveHomeSectionItems(
        section: section.copyWith(hideWatched: true),
        entries: [entry('tt3'), entry('tt4')],
        lookup: lookup,
        hiddenLibraryKeys: const {},
      );
      expect(items.map((i) => i.id), ['four']);
    });
  });

  group('LibraryExternalIdIndex', () {
    late StreamController<LibraryChangeEvent> events;
    setUp(() => events = StreamController<LibraryChangeEvent>.broadcast());
    tearDown(() => events.close());

    test('matches by IMDb across kinds, and by TMDB only within a kind', () async {
      final movie = _item('movie603');
      final show = _item('show603', kind: MediaKind.show);
      final client = _IndexClient([
        (item: movie, ids: const ExternalIds(imdb: 'tt0133093', tmdb: 603)),
        (item: show, ids: const ExternalIds(tmdb: 603, tvdb: 1)),
      ]);
      final index = LibraryExternalIdIndex(clientFor: (_) => client, libraryEvents: events.stream);
      await index.ensureLoaded(['s1']);

      expect(index.lookup(const ExternalIds(imdb: 'TT0133093'), serverIds: ['s1']), [movie]);
      expect(index.lookup(const ExternalIds(tmdb: 603), kind: MediaKind.show, serverIds: ['s1']), [show]);
      expect(index.lookup(const ExternalIds(tmdb: 603), serverIds: ['s1']), isEmpty, reason: 'TMDB needs a kind');
      expect(index.lookup(const ExternalIds(imdb: 'tt0133093'), serverIds: ['other']), isEmpty);
      index.dispose();
    });

    test('reuses a fresh index, rebuilds after a library change or TTL', () async {
      var now = DateTime(2026);
      final client = _IndexClient([]);
      final index = LibraryExternalIdIndex(
        clientFor: (_) => client,
        libraryEvents: events.stream,
        ttl: const Duration(minutes: 30),
        now: () => now,
      );
      await Future.wait([
        index.ensureLoaded(['s1']),
        index.ensureLoaded(['s1']),
      ]);
      expect(client.sweeps, 1, reason: 'concurrent loads share one sweep');

      await index.ensureLoaded(['s1']);
      expect(client.sweeps, 1);

      events.add(LibraryChangeEvent(serverId: ServerId('s1'), itemsAdded: true));
      await Future<void>.delayed(Duration.zero);
      await index.ensureLoaded(['s1']);
      expect(client.sweeps, 2);

      now = now.add(const Duration(minutes: 31));
      await index.ensureLoaded(['s1']);
      expect(client.sweeps, 3);
      index.dispose();
    });

    test('a failed sweep keeps the previous index', () async {
      var now = DateTime(2026);
      final movie = _item('m');
      var fail = false;
      final client = _IndexClient([(item: movie, ids: const ExternalIds(imdb: 'tt1'))]);
      final index = LibraryExternalIdIndex(
        clientFor: (_) => fail ? _ThrowingClient() : client,
        libraryEvents: events.stream,
        now: () => now,
      );
      await index.ensureLoaded(['s1']);
      fail = true;
      now = now.add(const Duration(hours: 2));
      await index.ensureLoaded(['s1']);
      expect(index.lookup(const ExternalIds(imdb: 'tt1'), serverIds: ['s1']), [movie]);
      index.dispose();
    });
  });

  test('index keys namespace TMDB/TVDB by kind', () {
    expect(externalIdIndexKeys(const ExternalIds(imdb: 'tt1', tmdb: 2, tvdb: 3), kind: MediaKind.movie), [
      'imdb:tt1',
      'tmdb:movie:2',
      'tvdb:movie:3',
    ]);
    expect(externalIdIndexKeys(const ExternalIds(imdb: 'tt1', tmdb: 2)), ['imdb:tt1']);
  });
}

class _ThrowingClient implements MediaServerClient {
  @override
  Future<List<ExternalIdIndexEntry>> fetchExternalIdIndex({AbortController? abort}) async => throw StateError('down');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
