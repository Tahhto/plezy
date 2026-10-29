import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_hub.dart';
import 'package:plezy/models/home_sections/home_layout.dart';

MediaHub _hub(String identifier, {String serverId = 's1'}) => MediaHub(
  id: identifier,
  identifier: identifier,
  title: identifier,
  type: 'mixed',
  items: const [],
  serverId: serverId,
);

const _a = CustomHomeSection(id: 'a', title: 'A', url: 'https://trakt.tv/lists/1');
const _b = CustomHomeSection(id: 'b', title: 'B', url: 'https://trakt.tv/lists/2');

void main() {
  final movies = _hub('library.m.recent');
  final shows = _hub('library.s.recent');
  final customA = _hub('custom.a', serverId: 's1');
  final customB = _hub('custom.b', serverId: 's1');

  List<String> titles(List<MediaHub> hubs) => [for (final hub in hubs) hub.title];

  group('composeHomeHubs', () {
    test('without a saved order, built-ins keep their order and custom rows follow', () {
      final hubs = composeHomeHubs(
        builtInHubs: [movies, shows],
        customHubs: {'a': customA, 'b': customB},
        layout: const HomeLayout(sections: [_a, _b]),
      );
      expect(titles(hubs), ['library.m.recent', 'library.s.recent', 'custom.a', 'custom.b']);
    });

    test('a saved order wins; unlisted rows fall in after it; hidden rows drop', () {
      final hubs = composeHomeHubs(
        builtInHubs: [movies, shows],
        customHubs: {'a': customA, 'b': customB},
        layout: HomeLayout(
          sections: const [_a, _b],
          order: ['custom:b', builtInHubLayoutKey(shows), 'hub:gone|library.x.recent'],
          hidden: {'custom:a'},
        ),
      );
      expect(titles(hubs), ['custom.b', 'library.s.recent', 'library.m.recent']);
    });

    test('custom sections that resolved to nothing are absent', () {
      final hubs = composeHomeHubs(
        builtInHubs: [movies],
        customHubs: {'a': customA},
        layout: const HomeLayout(sections: [_a, _b]),
      );
      expect(titles(hubs), ['library.m.recent', 'custom.a']);
    });

    test('built-in keys are scoped by server', () {
      final other = _hub('library.m.recent', serverId: 's2');
      expect(builtInHubLayoutKey(movies), isNot(builtInHubLayoutKey(other)));
      final hubs = composeHomeHubs(
        builtInHubs: [movies, other],
        customHubs: const {},
        layout: HomeLayout(hidden: {builtInHubLayoutKey(other)}),
      );
      expect(hubs, [movies]);
    });
  });

  group('moveHomeLayoutRow', () {
    test('moves within current rows and keeps absent saved keys at the end', () {
      const layout = HomeLayout(order: ['x', 'offline-row', 'y']);
      final moved = moveHomeLayoutRow(layout, ['x', 'y', 'z'], 'z', 0);
      expect(moved.order, ['z', 'x', 'y', 'offline-row']);
    });

    test('clamps out-of-range targets', () {
      final moved = moveHomeLayoutRow(HomeLayout.empty, ['x', 'y'], 'x', 10);
      expect(moved.order, ['y', 'x']);
    });
  });

  test('json round-trip, tolerating junk', () {
    const layout = HomeLayout(
      sections: [
        CustomHomeSection(
          id: 'a',
          title: 'A',
          url: 'u',
          kinds: HomeSectionKindFilter.shows,
          maxItems: 20,
          hideWatched: true,
        ),
      ],
      order: ['custom:a', 'hub:s1|x'],
      hidden: {'hub:s1|x'},
    );
    final decoded = HomeLayout.fromJson(layout.toJson());
    expect(decoded.sections.single.kinds, HomeSectionKindFilter.shows);
    expect(decoded.sections.single.maxItems, 20);
    expect(decoded.sections.single.hideWatched, isTrue);
    expect(decoded.order, layout.order);
    expect(decoded.hidden, layout.hidden);

    final junk = HomeLayout.fromJson({
      'sections': [
        {'id': 'ok', 'title': 'T', 'url': 'u', 'kinds': 'bogus', 'maxItems': -1},
        {'title': 'missing id'},
        42,
      ],
      'order': 'nope',
    });
    expect(junk.sections.single.kinds, HomeSectionKindFilter.all);
    expect(junk.sections.single.maxItems, CustomHomeSection.defaultMaxItems);
    expect(junk.order, isEmpty);
    expect(HomeLayout.fromJson(null).isEmpty, isTrue);
  });
}
