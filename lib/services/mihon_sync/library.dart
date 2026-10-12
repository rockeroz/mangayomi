// Reads and writes Mangayomi's library in the Mihon Sync format.
//
// Only entries from Mihon extensions take part: their source id and URL are the same as in
// Mihon, so the same manga is recognized on both sides. Chapter pages are 1-based in
// Mangayomi and 0-based in Mihon. Mangayomi keeps one history row per manga; Mihon keeps
// a last-read date per chapter.

import 'dart:io';
import 'dart:math' as math;

import 'package:collection/collection.dart';
import 'package:isar_community/isar.dart';
import 'package:mangayomi/main.dart';
import 'package:mangayomi/models/category.dart';
import 'package:mangayomi/models/chapter.dart';
import 'package:mangayomi/models/history.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/models/source.dart';
import 'package:mangayomi/repositories/db_write_queue.dart';
import 'package:mangayomi/services/extension_store_service.dart';
import 'package:mangayomi/services/http/m_client.dart';
import 'package:mangayomi/services/mihon_sync/merger.dart';
import 'package:mangayomi/services/mihon_sync/protocol.dart';
import 'package:mangayomi/services/mihon_sync/session.dart';
import 'package:mangayomi/services/mihon_sync/storage.dart';

ReadingPosition positionFromLocal(bool? isRead, String? lastPageRead) {
  final page = int.tryParse(lastPageRead ?? '') ?? 0;
  return ReadingPosition(read: isRead ?? false, page: page > 1 ? page - 1 : 0);
}

String lastPageReadFor(ReadingPosition position) =>
    position.page > 0 ? '${position.page + 1}' : '';

/// Mangayomi resets a finished chapter to its first page, while Mihon keeps the page.
ReadingPosition sharedPosition(Chapter chapter, SyncChapter? known) {
  final local = positionFromLocal(chapter.isRead, chapter.lastPageRead);
  final previous = known?.position.value;
  if (previous != null && previous.read && local.read && local.page == 0) return previous;
  return local;
}

String newCategoryUid() {
  final random = math.Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
      '${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// Shared category ids by local category id, kept per account like Mihon's sync_category_identity.
class CategoryIdentities {
  final JsonFile _file;
  Map<String, String> bindings = {};

  CategoryIdentities(File file) : _file = JsonFile(file) {
    try {
      final json = _file.read();
      if (json is Map) {
        bindings = {
          for (final entry in json.entries)
            if (entry.value is String) '${entry.key}': entry.value as String,
        };
      }
    } catch (_) {
      bindings = {};
    }
  }

  void save() => _file.write(bindings);

  List<SyncCategory> snapshot(List<Category> local, SyncDocument known) {
    final remote = <String, SyncCategory>{
      for (final category in known.categoryDefinitions)
        if (!category.deleted.value) category.name.value: category,
    };
    final deleted = {
      for (final category in known.categoryDefinitions)
        if (category.deleted.value) category.id,
    };
    final result = [
      for (final category in local)
        SyncCategory(
          id: bindings.putIfAbsent('${category.id}', () {
            final name = category.name ?? '';
            final legacy = SyncCategories.legacyId(name);
            return remote[name]?.id ?? (deleted.contains(legacy) ? newCategoryUid() : legacy);
          }),
          name: SyncValue(category.name ?? ''),
          order: SyncValue(math.max(0, category.pos ?? 0)),
        ),
    ];
    final ids = {for (final category in local) '${category.id}'};
    bindings.removeWhere((key, _) => !ids.contains(key));
    save();
    return result;
  }
}

class _RawChapter {
  final bool read;
  final String lastPageRead;
  final bool bookmark;
  const _RawChapter(this.read, this.lastPageRead, this.bookmark);

  factory _RawChapter.of(Chapter chapter) => _RawChapter(
    chapter.isRead ?? false,
    chapter.lastPageRead ?? '',
    chapter.isBookmarked ?? false,
  );

  @override
  bool operator ==(Object other) =>
      other is _RawChapter &&
      other.read == read &&
      other.lastPageRead == lastPageRead &&
      other.bookmark == bookmark;

  @override
  int get hashCode => Object.hash(read, lastPageRead, bookmark);
}

class MangayomiSyncLibrary implements SyncLibraryRepository {
  final CategoryIdentities identities;
  final MihonSourceIds sourceIds;

  /// Chapter states read by [snapshot], to recognize local edits made while HTTP was in flight.
  final Map<int, _RawChapter> _observedChapters = {};

  /// Entries of the library that could not be matched to a Mihon extension source.
  int unmatchedEntries = 0;

  /// Received entries whose Mihon source is not listed in any repository added to Mangayomi.
  int unavailableEntries = 0;

  MangayomiSyncLibrary(this.identities, this.sourceIds);

  static List<Category> _localCategories() => isar.categorys
      .filter()
      .forItemTypeEqualTo(ItemType.manga)
      .findAllSync()
      .sortedBy<num>((c) => c.pos ?? 0);

  /// Fetches the repository lists of Mihon sources whose original id is not known yet.
  Future<void> _resolveSourceIds(List<Manga> mangas) async {
    final unknown = {
      for (final manga in mangas)
        if (manga.sourceId != null && sourceIds.mihonIdFor(manga.sourceId) == null)
          manga.sourceId!,
    };
    if (unknown.isEmpty) return;
    final sources = isar.sources.getAllSync(unknown.toList()).whereType<Source>();
    final urls = {
      for (final source in sources)
        if (source.sourceCodeLanguage == SourceCodeLanguage.mihon &&
            (source.repo?.jsonUrl?.isNotEmpty ?? false))
          source.repo!.jsonUrl!,
    };
    for (final url in urls) {
      try {
        await ExtensionStoreService.fetchStore(
          url,
          MClient.init(reqcopyWith: {'useDartHttpClient': true}),
        ).timeout(const Duration(seconds: 30));
      } catch (_) {
        // Entries of this repository stay out of this pass and are retried later.
      }
    }
  }

  @override
  Future<SyncSnapshot> snapshot(SyncDocument known) async {
    final candidates = isar.mangas
        .filter()
        .itemTypeEqualTo(ItemType.manga)
        .findAllSync()
        .where((m) => !(m.isLocalArchive ?? false) && (m.link?.isNotEmpty ?? false))
        .toList();
    await _resolveSourceIds(candidates);
    final definitions = identities.snapshot(_localCategories(), known);
    final uidByLocal = Map<String, String>.of(identities.bindings);
    final knownMangas = {for (final manga in known.mangas) manga.key: manga};
    _observedChapters.clear();
    unmatchedEntries = 0;
    final mangas = <SyncManga>[];
    isar.txnSync(() {
      for (final manga in isar.mangas.getAllSync(candidates.map((m) => m.id!).toList())) {
        if (manga == null) continue;
        final mihonId = sourceIds.mihonIdFor(manga.sourceId);
        final chapters = isar.chapters.filter().mangaIdEqualTo(manga.id).findAllSync();
        final history = isar.historys.filter().mangaIdEqualTo(manga.id).findFirstSync();
        if (mihonId == null) {
          if (manga.favorite ?? false) unmatchedEntries++;
          continue;
        }
        final key = SyncKey(mihonId, manga.link!);
        final prior = knownMangas[key];
        final hasProgress = chapters.any(
          (c) =>
              (c.isRead ?? false) ||
              (c.isBookmarked ?? false) ||
              positionFromLocal(c.isRead, c.lastPageRead) != ReadingPosition.unread,
        );
        if (!(manga.favorite ?? false) && prior == null && !hasProgress && history == null) {
          continue;
        }
        final priorChapters = {
          for (final chapter in prior?.chapters ?? <SyncChapter>[]) chapter.url: chapter,
        };
        final readAt = int.tryParse(history?.date ?? '') ?? 0;
        final shared = <SyncChapter>[];
        final urls = <String>{};
        for (var index = 0; index < chapters.length; index++) {
          final chapter = chapters[index];
          final url = chapter.url ?? '';
          if (url.isEmpty || !urls.add(url)) continue;
          _observedChapters[chapter.id!] = _RawChapter.of(chapter);
          final before = priorChapters[url];
          shared.add(
            SyncChapter(
              url: url,
              name: before?.name ?? ((chapter.name?.isNotEmpty ?? false) ? chapter.name! : url),
              number: before?.number ?? -1.0,
              sourceOrder: before?.sourceOrder ?? (chapters.length - 1 - index),
              scanlator:
                  before?.scanlator ??
                  ((chapter.scanlator?.isNotEmpty ?? false) ? chapter.scanlator : null),
              position: SyncValue(sharedPosition(chapter, before)),
              bookmark: SyncValue(chapter.isBookmarked ?? false),
              lastReadAt: history?.chapterId == chapter.id && readAt > 0 ? readAt : 0,
            ),
          );
        }
        mangas.add(
          SyncManga(
            key: key,
            title: prior?.title ?? ((manga.name?.isNotEmpty ?? false) ? manga.name! : manga.link!),
            thumbnail: prior?.thumbnail ?? manga.imageUrl,
            favorite: SyncValue(manga.favorite ?? false),
            categories: {
              for (final id in manga.categories ?? const <int>[])
                if (uidByLocal['$id'] != null) uidByLocal['$id']!: const SyncValue(true),
            },
            chapters: shared,
          ),
        );
      }
    });
    return SyncSnapshot(mangas: mangas, categoryDefinitions: definitions);
  }

  @override
  Future<void> apply(SyncDocument remote, SyncSnapshot observed) async {
    remote.validate();
    final before = {for (final manga in observed.mangas) manga.key: manga};
    unavailableEntries = 0;
    await dbWriteQueue.run(() {
      isar.writeTxnSync(() {
        final categoryIds = _restoreCategories(remote, observed);
        final now = DateTime.now().millisecondsSinceEpoch;
        final existing = <String, Manga>{
          for (final manga in isar.mangas.filter().itemTypeEqualTo(ItemType.manga).findAllSync())
            if (manga.sourceId != null && manga.link != null) '${manga.sourceId}\n${manga.link}': manga,
        };
        for (final entry in remote.mangas) {
          final localSourceId = sourceIds.localIdForMihon(entry.key.source);
          final source = isar.sources.getSync(localSourceId);
          if (source == null) {
            unavailableEntries++;
            continue;
          }
          sourceIds.confirm(localSourceId, entry.key.source);
          _applyManga(
            entry,
            before[entry.key],
            existing['$localSourceId\n${entry.key.url}'],
            source,
            categoryIds,
            now,
          );
        }
      });
    });
  }

  void _applyManga(
    SyncManga entry,
    SyncManga? old,
    Manga? found,
    Source source,
    Map<String, int> categoryIds,
    int now,
  ) {
    final manga =
        found ??
        Manga(
          source: source.name,
          author: null,
          artist: null,
          genre: const [],
          imageUrl: entry.thumbnail,
          lang: source.lang,
          link: entry.key.url,
          name: entry.title,
          status: Status.unknown,
          description: null,
          sourceId: source.id,
          itemType: ItemType.manga,
          favorite: false,
          categories: const [],
          dateAdded: now,
          lastUpdate: now,
          updatedAt: now,
        );
    var changed = found == null;
    // Preserve edits made while HTTP was in flight. They are uploaded on the next pass.
    if ((manga.favorite ?? false) == (old?.favorite.value ?? false) &&
        (manga.favorite ?? false) != entry.favorite.value) {
      manga.favorite = entry.favorite.value;
      if (entry.favorite.value) manga.dateAdded ??= now;
      changed = true;
    }
    final current = {...?manga.categories};
    final observedCategories = {
      for (final category in old?.categories.entries ?? <MapEntry<String, SyncValue<bool>>>[])
        if (category.value.value) category.key,
    };
    final desired = Set<int>.of(current);
    entry.categories.forEach((uid, member) {
      final id = categoryIds[uid];
      if (id == null) return;
      if (current.contains(id) == observedCategories.contains(uid)) {
        if (member.value) {
          desired.add(id);
        } else {
          desired.remove(id);
        }
      }
    });
    if (!const SetEquality<int>().equals(desired, current)) {
      manga.categories = desired.toList();
      changed = true;
    }
    var lastReadAt = 0;
    for (final chapter in entry.chapters) {
      lastReadAt = math.max(lastReadAt, chapter.lastReadAt);
    }
    if (lastReadAt > (manga.lastRead ?? 0)) {
      manga.lastRead = lastReadAt;
      changed = true;
    }
    if (changed) {
      manga.updatedAt = now;
      isar.mangas.putSync(manga);
    }

    final oldChapters = {for (final chapter in old?.chapters ?? <SyncChapter>[]) chapter.url: chapter};
    final localChapters = <String, Chapter>{
      for (final chapter in isar.chapters.filter().mangaIdEqualTo(manga.id).findAllSync())
        if (chapter.url != null && chapter.url!.isNotEmpty) chapter.url!: chapter,
    };
    final updated = <Chapter>[];
    final created = <Chapter>[];
    for (final chapter in entry.chapters) {
      final local = localChapters[chapter.url];
      if (local == null) {
        created.add(
          Chapter(
            mangaId: manga.id,
            name: chapter.name,
            url: chapter.url,
            dateUpload: '$now',
            scanlator: chapter.scanlator ?? '',
            isRead: chapter.position.value.read,
            lastPageRead: lastPageReadFor(chapter.position.value),
            isBookmarked: chapter.bookmark.value,
            updatedAt: now,
          ),
        );
        continue;
      }
      final observedState = _observedChapters[local.id];
      final currentState = _RawChapter.of(local);
      final positionUnchanged = observedState != null
          ? observedState.read == currentState.read &&
                observedState.lastPageRead == currentState.lastPageRead
          : positionFromLocal(local.isRead, local.lastPageRead) == ReadingPosition.unread;
      var chapterChanged = false;
      if (positionUnchanged &&
          sharedPosition(local, oldChapters[chapter.url]) != chapter.position.value &&
          !(chapter.position.value.read &&
              (local.isRead ?? false) &&
              positionFromLocal(local.isRead, local.lastPageRead).page == 0)) {
        local.isRead = chapter.position.value.read;
        local.lastPageRead = lastPageReadFor(chapter.position.value);
        chapterChanged = true;
      }
      final bookmarkUnchanged = observedState != null
          ? observedState.bookmark == currentState.bookmark
          : !(local.isBookmarked ?? false);
      if (bookmarkUnchanged && (local.isBookmarked ?? false) != chapter.bookmark.value) {
        local.isBookmarked = chapter.bookmark.value;
        chapterChanged = true;
      }
      if (chapterChanged) {
        local.updatedAt = now;
        updated.add(local);
      }
    }
    if (updated.isNotEmpty) isar.chapters.putAllSync(updated);
    if (created.isNotEmpty) {
      // Mangayomi stores chapters oldest first; Mihon numbers them newest first.
      final order = {for (final chapter in entry.chapters) chapter.url: chapter.sourceOrder};
      final sorted = created.sortedBy<num>((c) => -(order[c.url] ?? 0));
      for (final chapter in sorted) {
        chapter.manga.value = manga;
        isar.chapters.putSync(chapter);
        chapter.manga.saveSync();
        localChapters[chapter.url!] = chapter;
      }
    }

    // History: Mangayomi keeps the last read chapter of each entry.
    SyncChapter? latest;
    for (final chapter in entry.chapters) {
      if (chapter.lastReadAt > 0 && (latest == null || chapter.lastReadAt > latest.lastReadAt)) {
        latest = chapter;
      }
    }
    if (latest != null) {
      final chapter = localChapters[latest.url];
      if (chapter != null) {
        final history = isar.historys.filter().mangaIdEqualTo(manga.id).findFirstSync();
        final date = int.tryParse(history?.date ?? '') ?? 0;
        if (latest.lastReadAt > date) {
          final row =
              history ??
              History(
                mangaId: manga.id,
                chapterId: chapter.id,
                date: '${latest.lastReadAt}',
                itemType: ItemType.manga,
              );
          row
            ..chapterId = chapter.id
            ..date = '${latest.lastReadAt}'
            ..updatedAt = now;
          row.chapter.value = chapter;
          isar.historys.putSync(row);
          row.chapter.saveSync();
        }
      }
    }
  }

  /// Mirrors Mihon's SyncCategoryRestorer. Returns local category ids by shared id.
  Map<String, int> _restoreCategories(SyncDocument remote, SyncSnapshot observed) {
    final bindings = identities.bindings;
    var local = _localCategories();
    final observedByUid = {
      for (final category in observed.categoryDefinitions) category.id: category,
    };
    // Checked before deleting identities: a deleted row must not look like a concurrent order edit.
    final orderUnchanged = local.every((category) {
      final prior = observedByUid[bindings['${category.id}']];
      return prior?.order.value == math.max(0, category.pos ?? 0);
    });
    final result = <String, int>{};
    for (final definition in remote.categoryDefinitions) {
      final existing = local.firstWhereOrNull((c) => bindings['${c.id}'] == definition.id);
      final before = observedByUid[definition.id];
      if (definition.deleted.value) {
        if (existing != null &&
            before != null &&
            existing.name == before.name.value &&
            math.max(0, existing.pos ?? 0) == before.order.value) {
          for (final manga in isar.mangas.filter().categoriesElementEqualTo(existing.id!).findAllSync()) {
            manga.categories = [...?manga.categories]..remove(existing.id);
            isar.mangas.putSync(manga);
          }
          isar.categorys.deleteSync(existing.id!);
          bindings.remove('${existing.id}');
          local = local.where((c) => c.id != existing.id).toList();
        }
        continue;
      }
      // A category present in the snapshot but now absent was deleted locally during HTTP.
      if (existing == null && before != null) continue;
      final matched =
          existing ?? local.firstWhereOrNull((c) => c.name == definition.name.value);
      final Category category;
      if (matched != null) {
        category = matched;
      } else {
        category = Category(
          name: definition.name.value,
          forItemType: ItemType.manga,
          pos: definition.order.value,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        );
        isar.categorys.putSync(category);
        local = [...local, category];
      }
      final categoryId = category.id;
      if (existing != null &&
          before != null &&
          category.name == before.name.value &&
          category.name != definition.name.value &&
          !local.any((c) => c.id != categoryId && c.name == definition.name.value)) {
        category.name = definition.name.value;
        category.updatedAt = DateTime.now().millisecondsSinceEpoch;
        isar.categorys.putSync(category);
      }
      bindings['${category.id}'] = definition.id;
      result[definition.id] = category.id!;
    }
    if (orderUnchanged && remote.categoryDefinitions.isNotEmpty) {
      // Mihon stores the shared order values; keeping them unchanged avoids reordering back and forth.
      for (final definition in remote.categoryDefinitions) {
        if (definition.deleted.value) continue;
        final id = result[definition.id];
        final category = local.firstWhereOrNull((c) => c.id == id);
        if (category != null && category.pos != definition.order.value) {
          category.pos = definition.order.value;
          category.updatedAt = DateTime.now().millisecondsSinceEpoch;
          isar.categorys.putSync(category);
        }
      }
    }
    identities.save();
    return {
      ...result,
      for (final entry in bindings.entries)
        if (int.tryParse(entry.key) != null) entry.value: int.parse(entry.key),
    };
  }
}
