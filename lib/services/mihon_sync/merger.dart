// Merge rules of Mihon Sync 0.7.2, ported from the Android app (SyncMerger, SyncCategories,
// SyncDelta and SyncOptions). Every device must compute the same results, so this file
// follows the Kotlin code line by line rather than re-designing it.

import 'dart:convert';
import 'dart:math' as math;

import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';
import 'package:mangayomi/services/mihon_sync/protocol.dart';

const _deep = DeepCollectionEquality();

bool _same(Object? a, Object? b) => _deep.equals(a, b);

SyncValue<T> _newest<T>(SyncValue<T> a, SyncValue<T> b) => a.version >= b.version ? a : b;

String _maxString(String a, String b) => compareStrings(a, b) >= 0 ? a : b;

String? _maxNullableString(String? a, String? b) {
  if (a == null) return b;
  if (b == null) return a;
  return _maxString(a, b);
}

int _compareMangaKeys(SyncManga a, SyncManga b) => compareKeys(a.key, b.key);

class SyncCategories {
  static String legacyId(String name) =>
      'name-${sha256.convert(utf8.encode(name))}';

  /// Older documents used category names as membership keys. Convert them exactly once.
  static SyncDocument upgrade(SyncDocument document) {
    if (document.schema >= 4) return document;
    final names = <String>{
      ...document.categoryNames,
      for (final manga in document.mangas) ...manga.categories.keys,
    }.toList()..sort(compareStrings);
    return document.copyWith(
      schema: 4,
      categoryNames: const {},
      categoryDefinitions: [
        for (final name in names) SyncCategory(id: legacyId(name), name: SyncValue(name)),
      ],
      mangas: [
        for (final manga in document.mangas)
          manga.copyWith(
            categories: {
              for (final entry in manga.categories.entries) legacyId(entry.key): entry.value,
            },
          ),
      ],
    );
  }

  static List<SyncCategory> capture(
    List<SyncCategory> before,
    List<SyncCategory> local,
    SyncVersion version,
  ) {
    final old = {for (final category in before) category.id: category};
    SyncValue<T> changed<T>(T value, SyncValue<T>? prior) =>
        prior != null && prior.value == value ? prior : SyncValue(value, version);
    final present = [
      for (final category in local)
        () {
          final previous = old[category.id];
          return category.copyWith(
            name: changed(category.name.value, previous?.name),
            order: changed(category.order.value, previous?.order),
            deleted: previous == null && !category.deleted.value
                ? const SyncValue(false)
                : changed(category.deleted.value, previous?.deleted),
          );
        }(),
    ];
    final ids = {for (final category in present) category.id};
    return [
      ...present,
      for (final category in before)
        if (!ids.contains(category.id))
          category.deleted.value
              ? category
              : category.copyWith(deleted: SyncValue(true, version)),
    ];
  }

  static List<SyncCategory> merge(List<SyncCategory> first, List<SyncCategory> second) {
    final grouped = <String, SyncCategory>{};
    for (final category in [...first, ...second]) {
      final current = grouped[category.id];
      grouped[category.id] = current == null
          ? category
          : current.copyWith(
              name: _newest(current.name, category.name),
              order: _newest(current.order, category.order),
              deleted: _newest(current.deleted, category.deleted),
            );
    }
    return grouped.values.toList()..sort((a, b) => compareStrings(a.id, b.id));
  }
}

class SyncMerger {
  /// Three-way reconciliation: unchanged local values retain their original version.
  static SyncDocument capture(
    SyncDocument previousDocument,
    SyncSnapshot local,
    String device,
    int now, [
    SyncDocument? received,
  ]) {
    final baseline = SyncCategories.upgrade(previousDocument);
    syncRequire(device.trim().isNotEmpty);
    final previous = {for (final manga in baseline.mangas) manga.key: manga};
    final inbound = {for (final manga in received?.mangas ?? <SyncManga>[]) manga.key: manga};
    var highest = 0;
    for (final manga in [...baseline.mangas, ...?received?.mangas]) {
      var value = math.max(manga.favorite.version.time, manga.reader.version.time);
      value = math.max(value, manga.tracks.version.time);
      for (final category in manga.categories.values) {
        value = math.max(value, category.version.time);
      }
      for (final chapter in manga.chapters) {
        value = math.max(
          value,
          math.max(chapter.position.version.time, chapter.bookmark.version.time),
        );
      }
      highest = math.max(highest, value);
    }
    var categoryTime = 0;
    for (final category in [
      ...baseline.categoryDefinitions,
      ...?received?.categoryDefinitions,
    ]) {
      categoryTime = math.max(
        categoryTime,
        math.max(
          category.name.version.time,
          math.max(category.order.version.time, category.deleted.version.time),
        ),
      );
    }
    final version = SyncVersion(
      math.max(now, math.max(highest + 1, categoryTime + 1)),
      device,
    );
    final observed = [
      for (final manga in local.mangas)
        () {
          final old = previous[manga.key];
          final imported = inbound[manga.key];
          final importedChapters = {
            for (final chapter in imported?.chapters ?? <SyncChapter>[]) chapter.url: chapter,
          };
          final oldChapters = {
            for (final chapter in old?.chapters ?? <SyncChapter>[]) chapter.url: chapter,
          };
          final localChapterUrls = {for (final chapter in manga.chapters) chapter.url};
          final categoryNames = <String>{
            ...manga.categories.keys,
            ...?old?.categories.keys,
            ...?imported?.categories.keys,
          };
          return manga.copyWith(
            favorite: _changed(
              manga.favorite.value,
              old?.favorite,
              false,
              version,
              imported?.favorite,
            ),
            reader: _changedReader(manga.reader.value, old?.reader, version, imported?.reader),
            tracks: _changed<List<SyncTrack>>(
              manga.tracks.value,
              old?.tracks,
              const <SyncTrack>[],
              version,
              imported?.tracks,
            ),
            categories: {
              for (final name in categoryNames)
                name: _changed(
                  manga.categories[name]?.value == true,
                  old?.categories[name],
                  false,
                  version,
                  imported?.categories[name],
                ),
            },
            chapters: [
              for (final chapter in manga.chapters)
                chapter.copyWith(
                  position: _changed(
                    chapter.position.value,
                    oldChapters[chapter.url]?.position,
                    ReadingPosition.unread,
                    version,
                    importedChapters[chapter.url]?.position,
                  ),
                  bookmark: _changed(
                    chapter.bookmark.value,
                    oldChapters[chapter.url]?.bookmark,
                    false,
                    version,
                    importedChapters[chapter.url]?.bookmark,
                  ),
                ),
              for (final chapter in oldChapters.values)
                if (!localChapterUrls.contains(chapter.url)) chapter,
            ],
          );
        }(),
    ];
    // A locally purged database row is not evidence that the user removed it from the library.
    final localKeys = {for (final manga in local.mangas) manga.key};
    final mangas = [
      ...observed,
      for (final manga in baseline.mangas)
        if (!localKeys.contains(manga.key)) manga,
    ]..sort(_compareMangaKeys);
    return SyncDocument(
      mangas: mangas,
      categoryNames: {...baseline.categoryNames, ...local.categoryNames},
      catalog: baseline.catalog.merge(local.catalog),
      migrations: SyncMigration.merge(baseline.migrations, local.migrations),
      categoryDefinitions: SyncCategories.capture(
        baseline.categoryDefinitions,
        local.categoryDefinitions,
        version,
      ),
    );
  }

  static SyncValue<SyncReaderSettings?> _changedReader(
    SyncReaderSettings? value,
    SyncValue<SyncReaderSettings?>? before,
    SyncVersion version,
    SyncValue<SyncReaderSettings?>? received,
  ) {
    final unconfigured =
        before == null || (before.value == null && before.version == SyncVersion.zero);
    if (unconfigured && value == SyncReaderSettings.unset && received?.value != value) {
      return SyncValue(value);
    }
    return _changed<SyncReaderSettings?>(value, before, null, version, received);
  }

  static SyncValue<T> _changed<T>(
    T value,
    SyncValue<T>? before,
    T defaultValue,
    SyncVersion version, [
    SyncValue<T>? received,
  ]) {
    // After a crash between the database commit and the journal commit, recognize imported values.
    if (received != null && _same(received.value, value)) return received;
    if (before != null && _same(before.value, value)) return before;
    // An empty/unread state on a newly linked device must never undo remote data.
    return SyncValue(
      value,
      before == null && _same(value, defaultValue) ? SyncVersion.zero : version,
    );
  }

  static SyncDocument merge(SyncDocument first, SyncDocument second) {
    first.validate();
    second.validate();
    final leftDocument = SyncCategories.upgrade(first);
    final rightDocument = SyncCategories.upgrade(second);
    final a = {for (final manga in leftDocument.mangas) manga.key: manga};
    final b = {for (final manga in rightDocument.mangas) manga.key: manga};
    final keys = <SyncKey>{...a.keys, ...b.keys};
    final mangas = [
      for (final key in keys)
        if (a[key] == null)
          b[key]!
        else if (b[key] == null)
          a[key]!
        else
          _mergeManga(a[key]!, b[key]!),
    ]..sort(_compareMangaKeys);
    return SyncDocument(
      mangas: mangas,
      categoryNames: {...leftDocument.categoryNames, ...rightDocument.categoryNames},
      catalog: first.catalog.merge(second.catalog),
      migrations: SyncMigration.merge(first.migrations, second.migrations),
      categoryDefinitions: SyncCategories.merge(
        leftDocument.categoryDefinitions,
        rightDocument.categoryDefinitions,
      ),
    );
  }

  static SyncManga _mergeManga(SyncManga a, SyncManga b) {
    final ac = {for (final chapter in a.chapters) chapter.url: chapter};
    final bc = {for (final chapter in b.chapters) chapter.url: chapter};
    final urls = <String>{...ac.keys, ...bc.keys};
    final categoryNames = <String>{...a.categories.keys, ...b.categories.keys};
    final chapters = [
      for (final url in urls)
        if (ac[url] == null)
          bc[url]!
        else if (bc[url] == null)
          ac[url]!
        else
          _mergeChapter(ac[url]!, bc[url]!),
    ]..sort((x, y) => compareStrings(x.url, y.url));
    return SyncManga(
      key: a.key,
      title: _maxString(a.title, b.title),
      thumbnail: _maxNullableString(a.thumbnail, b.thumbnail),
      favorite: _newest(a.favorite, b.favorite),
      reader: _newest(a.reader, b.reader),
      tracks: _newest(a.tracks, b.tracks),
      categories: {
        for (final name in categoryNames)
          name: _newest(
            a.categories[name] ?? const SyncValue(false),
            b.categories[name] ?? const SyncValue(false),
          ),
      },
      chapters: chapters,
    );
  }

  static SyncChapter _mergeChapter(SyncChapter left, SyncChapter right) => SyncChapter(
    url: left.url,
    name: _maxString(left.name, right.name),
    number: math.max(left.number, right.number),
    sourceOrder: math.max(left.sourceOrder, right.sourceOrder),
    scanlator: _maxNullableString(left.scanlator, right.scanlator),
    position: _newest(left.position, right.position),
    bookmark: _newest(left.bookmark, right.bookmark),
    lastReadAt: math.max(left.lastReadAt, right.lastReadAt),
  );
}

/// A mergeable document carrying only changed entries and changed chapters within them.
class SyncDelta {
  static SyncDocument between(SyncDocument before, SyncDocument after) {
    final previous = {for (final manga in before.mangas) manga.key: manga};
    final definitions = {for (final category in before.categoryDefinitions) category.id: category};
    final beforeStores = before.catalog.stores.toSet();
    final beforeExtensions = before.catalog.extensions.toSet();
    final beforeMigrations = before.migrations.toSet();
    return after.copyWith(
      mangas: [
        for (final entry in after.mangas)
          if (previous[entry.key] != entry)
            () {
              final old = previous[entry.key];
              if (old == null) return entry;
              final chapters = {for (final chapter in old.chapters) chapter.url: chapter};
              return SyncManga(
                key: entry.key,
                title: entry.title,
                thumbnail: entry.thumbnail,
                favorite: entry.favorite,
                chapters: [
                  for (final chapter in entry.chapters)
                    if (chapters[chapter.url] != chapter) chapter,
                ],
                categories: {
                  for (final category in entry.categories.entries)
                    if (old.categories[category.key] != category.value)
                      category.key: category.value,
                },
                reader: entry.reader == old.reader
                    ? const SyncValue<SyncReaderSettings?>(null)
                    : entry.reader,
                tracks: entry.tracks == old.tracks
                    ? const SyncValue(<SyncTrack>[])
                    : entry.tracks,
              );
            }(),
      ],
      categoryNames: after.categoryNames.difference(before.categoryNames),
      categoryDefinitions: [
        for (final category in after.categoryDefinitions)
          if (definitions[category.id] != category) category,
      ],
      catalog: SyncCatalog(
        [for (final store in after.catalog.stores) if (!beforeStores.contains(store)) store],
        [
          for (final extension in after.catalog.extensions)
            if (!beforeExtensions.contains(extension)) extension,
        ],
      ),
      migrations: [
        for (final migration in after.migrations)
          if (!beforeMigrations.contains(migration)) migration,
      ],
    );
  }
}

/// Which groups of data this device shares, as in Mihon Sync's per-device options.
class SyncOptions {
  final bool library;
  final bool progress;
  final bool categories;
  final bool history;
  final bool stores;
  final bool extensions;
  final bool migrations;
  final bool reader;
  final bool tracking;

  const SyncOptions({
    this.library = true,
    this.progress = true,
    this.categories = true,
    this.history = true,
    this.stores = true,
    this.extensions = true,
    this.migrations = true,
    this.reader = false,
    this.tracking = false,
  });

  /// Mangayomi shares the library, progress, categories and history. Mihon-only groups
  /// (extension stores, extensions, migrations, reader flags and trackers) are kept as received.
  static const mangayomi = SyncOptions(
    stores: false,
    extensions: false,
    migrations: false,
  );

  factory SyncOptions.fromJson(Object? json) {
    final map = json is Map ? json.cast<String, dynamic>() : const <String, dynamic>{};
    bool read(String key, bool fallback) => map[key] is bool ? map[key] as bool : fallback;
    return SyncOptions(
      library: read('library', true),
      progress: read('progress', true),
      categories: read('categories', true),
      history: read('history', true),
      stores: read('stores', true),
      extensions: read('extensions', true),
      migrations: read('migrations', true),
      reader: read('reader', false),
      tracking: read('tracking', false),
    );
  }

  Map<String, dynamic> toJson() => {
    'library': library,
    'progress': progress,
    'categories': categories,
    'history': history,
    'stores': stores,
    'extensions': extensions,
    'migrations': migrations,
    'reader': reader,
    'tracking': tracking,
  };

  /// A newly enabled group behaves like a newly linked device, rather than deleting unseen remote data.
  SyncDocument captureBaseline(SyncDocument document, SyncOptions previous) => document.copyWith(
    mangas: [
      for (final manga in document.mangas)
        manga.copyWith(
          favorite: library && !previous.library ? const SyncValue(false) : manga.favorite,
          categories: categories && !previous.categories ? const {} : manga.categories,
          reader: reader && !previous.reader
              ? const SyncValue<SyncReaderSettings?>(null)
              : manga.reader,
          tracks: tracking && !previous.tracking ? const SyncValue(<SyncTrack>[]) : manga.tracks,
          chapters: [
            for (final chapter in manga.chapters)
              chapter.copyWith(
                position: progress && !previous.progress
                    ? const SyncValue(ReadingPosition.unread)
                    : chapter.position,
                bookmark: progress && !previous.progress
                    ? const SyncValue(false)
                    : chapter.bookmark,
              ),
          ],
        ),
    ],
    categoryDefinitions: categories && !previous.categories
        ? const []
        : document.categoryDefinitions,
  );

  SyncSnapshot captureSnapshot(SyncSnapshot local, SyncDocument known) {
    final old = {for (final manga in known.mangas) manga.key: manga};
    bool selected(SyncManga manga) =>
        old.containsKey(manga.key) ||
        library ||
        (progress &&
            manga.chapters.any(
              (c) => c.position.value != ReadingPosition.unread || c.bookmark.value,
            )) ||
        (history && manga.chapters.any((c) => c.lastReadAt > 0)) ||
        (reader &&
            manga.reader.value != null &&
            manga.reader.value != SyncReaderSettings.unset) ||
        (tracking && manga.tracks.value.isNotEmpty);
    return local.copyWith(
      mangas: [
        for (final manga in local.mangas.where(selected))
          () {
            final prior = old[manga.key];
            final chapters = {
              for (final chapter in prior?.chapters ?? <SyncChapter>[]) chapter.url: chapter,
            };
            return manga.copyWith(
              favorite: library ? manga.favorite : prior?.favorite ?? const SyncValue(false),
              categories: categories ? manga.categories : prior?.categories ?? const {},
              reader: reader
                  ? manga.reader
                  : prior?.reader ?? const SyncValue<SyncReaderSettings?>(null),
              tracks: tracking
                  ? manga.tracks
                  : prior?.tracks ?? const SyncValue(<SyncTrack>[]),
              chapters: [
                for (final chapter in manga.chapters)
                  chapter.copyWith(
                    position: progress
                        ? chapter.position
                        : chapters[chapter.url]?.position ??
                              const SyncValue(ReadingPosition.unread),
                    bookmark: progress
                        ? chapter.bookmark
                        : chapters[chapter.url]?.bookmark ?? const SyncValue(false),
                    lastReadAt: history
                        ? chapter.lastReadAt
                        : chapters[chapter.url]?.lastReadAt ?? 0,
                  ),
              ],
            );
          }(),
      ],
      categoryNames: categories ? local.categoryNames : known.categoryNames,
      categoryDefinitions: categories ? local.categoryDefinitions : known.categoryDefinitions,
      catalog: SyncCatalog(
        stores ? local.catalog.stores : known.catalog.stores,
        extensions ? local.catalog.extensions : known.catalog.extensions,
      ),
      migrations: migrations ? local.migrations : known.migrations,
    );
  }

  SyncDocument applyDocument(SyncDocument remote, SyncSnapshot local) {
    final rows = {for (final manga in local.mangas) manga.key: manga};
    bool hasSelectedData(SyncChapter chapter) =>
        (progress &&
            (chapter.position.value != ReadingPosition.unread || chapter.bookmark.value)) ||
        (history && chapter.lastReadAt > 0);
    return remote.copyWith(
      mangas: [
        for (final manga in remote.mangas)
          if (rows.containsKey(manga.key) ||
              library ||
              manga.chapters.any(hasSelectedData) ||
              (reader &&
                  manga.reader.value != null &&
                  manga.reader.value != SyncReaderSettings.unset) ||
              (tracking && manga.tracks.value.isNotEmpty))
            () {
              final current = rows[manga.key];
              final chapters = {
                for (final chapter in current?.chapters ?? <SyncChapter>[]) chapter.url: chapter,
              };
              return manga.copyWith(
                favorite: library ? manga.favorite : current?.favorite ?? const SyncValue(false),
                categories: categories ? manga.categories : current?.categories ?? const {},
                reader: reader
                    ? manga.reader
                    : current?.reader ?? const SyncValue<SyncReaderSettings?>(null),
                tracks: tracking
                    ? manga.tracks
                    : current?.tracks ?? const SyncValue(<SyncTrack>[]),
                chapters: [
                  for (final chapter in manga.chapters)
                    if (chapters.containsKey(chapter.url) || library || hasSelectedData(chapter))
                      chapter.copyWith(
                        position: progress
                            ? chapter.position
                            : chapters[chapter.url]?.position ??
                                  const SyncValue(ReadingPosition.unread),
                        bookmark: progress
                            ? chapter.bookmark
                            : chapters[chapter.url]?.bookmark ?? const SyncValue(false),
                        lastReadAt: history
                            ? chapter.lastReadAt
                            : chapters[chapter.url]?.lastReadAt ?? 0,
                      ),
                ],
              );
            }(),
      ],
      categoryNames: categories ? remote.categoryNames : local.categoryNames,
      categoryDefinitions: categories ? remote.categoryDefinitions : local.categoryDefinitions,
      catalog: SyncCatalog(
        stores ? remote.catalog.stores : local.catalog.stores,
        extensions ? remote.catalog.extensions : local.catalog.extensions,
      ),
      migrations: migrations ? remote.migrations : local.migrations,
    );
  }
}
