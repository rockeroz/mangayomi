import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';
import 'package:mangayomi/main.dart';
import 'package:mangayomi/models/category.dart';
import 'package:mangayomi/models/chapter.dart';
import 'package:mangayomi/models/history.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/models/source.dart';
import 'package:mangayomi/services/mihon_sync/library.dart';
import 'package:mangayomi/services/mihon_sync/merger.dart';
import 'package:mangayomi/services/mihon_sync/protocol.dart';
import 'package:mangayomi/services/mihon_sync/storage.dart';

const _mihonSourceId = 2499283573021220255;

void main() {
  late Directory directory;
  late MangayomiSyncLibrary library;
  late int sourceId;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final overrides = HttpOverrides.current;
    HttpOverrides.global = null;
    try {
      await Isar.initializeIsarCore(download: true);
    } finally {
      HttpOverrides.global = overrides;
    }
  });

  setUp(() async {
    directory = Directory.systemTemp.createTempSync('mihon_sync_library');
    isar = await Isar.open(
      [MangaSchema, ChapterSchema, HistorySchema, CategorySchema, SourceSchema],
      directory: directory.path,
      name: 'mihon_sync_${directory.path.hashCode}',
    );
    MihonSourceIds.instance.remember('$_mihonSourceId');
    sourceId = MihonSourceIds.localIdFor(_mihonSourceId);
    final source = Source(id: sourceId, name: 'Example', lang: 'es', isAdded: true)
      ..sourceCodeLanguage = SourceCodeLanguage.mihon
      ..itemType = ItemType.manga;
    isar.writeTxnSync(() => isar.sources.putSync(source));
    library = MangayomiSyncLibrary(
      CategoryIdentities(File('${directory.path}/categories.json')),
      MihonSourceIds.instance,
    );
  });

  tearDown(() async {
    await isar.close(deleteFromDisk: true);
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  Manga addManga({String link = '/manga/1', bool favorite = true, List<int> categories = const []}) {
    final manga = Manga(
      source: 'Example',
      author: null,
      artist: null,
      genre: const [],
      imageUrl: 'https://example.org/cover.jpg',
      lang: 'es',
      link: link,
      name: 'Book',
      status: Status.unknown,
      description: null,
      sourceId: sourceId,
      favorite: favorite,
      categories: categories,
    );
    isar.writeTxnSync(() => isar.mangas.putSync(manga));
    return manga;
  }

  Chapter addChapter(Manga manga, String url, {bool read = false, String page = '', bool bookmark = false}) {
    final chapter = Chapter(
      mangaId: manga.id,
      name: url,
      url: url,
      isRead: read,
      lastPageRead: page,
      isBookmarked: bookmark,
    )..manga.value = manga;
    isar.writeTxnSync(() {
      isar.chapters.putSync(chapter);
      chapter.manga.saveSync();
    });
    return chapter;
  }

  test('the library is shared with Mihon source ids, 0-based pages and category ids', () async {
    final category = Category(name: 'Leyendo', forItemType: ItemType.manga, pos: 1);
    isar.writeTxnSync(() => isar.categorys.putSync(category));
    final manga = addManga(categories: [category.id!]);
    addChapter(manga, '/c/1', read: true, page: '1');
    final second = addChapter(manga, '/c/2', page: '5', bookmark: true);
    isar.writeTxnSync(
      () => isar.historys.putSync(
        History(mangaId: manga.id, chapterId: second.id, date: '1700000000000', itemType: ItemType.manga),
      ),
    );
    // A manga of another source and a browsed manga without progress are left out.
    isar.writeTxnSync(
      () => isar.mangas.putSync(
        Manga(
          source: 'Other',
          author: null,
          artist: null,
          genre: const [],
          imageUrl: null,
          lang: 'en',
          link: '/other',
          name: 'Other',
          status: Status.unknown,
          description: null,
          sourceId: 42,
          favorite: true,
        ),
      ),
    );
    addManga(link: '/browsed', favorite: false);

    final snapshot = await library.snapshot(const SyncDocument());
    final shared = snapshot.mangas.single;
    expect(shared.key, const SyncKey(_mihonSourceId, '/manga/1'));
    expect(shared.favorite.value, isTrue);
    expect(shared.chapters.map((c) => c.position.value), [
      const ReadingPosition(read: true),
      const ReadingPosition(page: 4),
    ]);
    expect(shared.chapters.last.bookmark.value, isTrue);
    expect(shared.chapters.last.lastReadAt, 1700000000000);
    expect(shared.chapters.first.lastReadAt, 0);
    final uid = SyncCategories.legacyId('Leyendo');
    expect(shared.categories, {uid: const SyncValue(true)});
    expect(snapshot.categoryDefinitions.single.id, uid);
    expect(snapshot.categoryDefinitions.single.order.value, 1);
    expect(library.unmatchedEntries, 1);
  });

  test('a finished chapter keeps the page Mihon stored', () async {
    final manga = addManga();
    addChapter(manga, '/c/1', read: true, page: '1');
    final known = SyncDocument(
      mangas: [
        SyncManga(
          key: const SyncKey(_mihonSourceId, '/manga/1'),
          title: 'Book',
          favorite: const SyncValue(true),
          chapters: const [
            SyncChapter(
              url: '/c/1',
              name: 'Chapter 1',
              number: 1,
              position: SyncValue(ReadingPosition(read: true, page: 17), SyncVersion(5, 'phone')),
            ),
          ],
        ),
      ],
    );
    final snapshot = await library.snapshot(known);
    final chapter = snapshot.mangas.single.chapters.single;
    expect(chapter.position.value, const ReadingPosition(read: true, page: 17));
    expect(chapter.name, 'Chapter 1');
    expect(chapter.number, 1.0);
  });

  test('received entries, progress, categories and history are applied', () async {
    final existing = addManga();
    final unread = addChapter(existing, '/c/1');
    final observed = await library.snapshot(const SyncDocument());
    final uid = SyncCategories.legacyId('Favoritos');
    final remote = SyncDocument(
      categoryDefinitions: [
        SyncCategory(id: uid, name: const SyncValue('Favoritos', SyncVersion(1, 'phone')), order: const SyncValue(2)),
      ],
      mangas: [
        SyncManga(
          key: const SyncKey(_mihonSourceId, '/manga/1'),
          title: 'Book',
          thumbnail: 'https://example.org/cover.jpg',
          favorite: const SyncValue(true),
          categories: {uid: const SyncValue(true, SyncVersion(1, 'phone'))},
          chapters: const [
            SyncChapter(
              url: '/c/1',
              name: '/c/1',
              position: SyncValue(ReadingPosition(page: 9), SyncVersion(2, 'phone')),
              lastReadAt: 1800000000000,
            ),
          ],
        ),
        const SyncManga(
          key: SyncKey(_mihonSourceId, '/manga/new'),
          title: 'New book',
          thumbnail: 'https://example.org/new.jpg',
          favorite: SyncValue(true, SyncVersion(3, 'phone')),
          chapters: [
            SyncChapter(url: '/n/2', name: 'Two', sourceOrder: 0),
            SyncChapter(
              url: '/n/1',
              name: 'One',
              sourceOrder: 1,
              position: SyncValue(ReadingPosition(read: true), SyncVersion(3, 'phone')),
              bookmark: SyncValue(true, SyncVersion(3, 'phone')),
            ),
          ],
        ),
        const SyncManga(
          key: SyncKey(99, '/unknown-source'),
          title: 'Unavailable',
          favorite: SyncValue(true, SyncVersion(3, 'phone')),
        ),
      ],
    );
    await library.apply(remote, observed);

    final chapter = isar.chapters.getSync(unread.id!)!;
    expect(chapter.lastPageRead, '10');
    expect(chapter.isRead, isFalse);
    final category = isar.categorys.filter().nameEqualTo('Favoritos').findFirstSync()!;
    expect(category.pos, 2);
    expect(isar.mangas.getSync(existing.id!)!.categories, [category.id]);
    final history = isar.historys.filter().mangaIdEqualTo(existing.id).findFirstSync()!;
    expect(history.chapterId, unread.id);
    expect(history.date, '1800000000000');

    final created = isar.mangas.filter().linkEqualTo('/manga/new').findFirstSync()!;
    expect(created.favorite, isTrue);
    expect(created.sourceId, sourceId);
    expect(created.name, 'New book');
    final chapters = isar.chapters.filter().mangaIdEqualTo(created.id).findAllSync();
    // Oldest first, as Mangayomi stores them.
    expect(chapters.map((c) => c.url), ['/n/1', '/n/2']);
    expect(chapters.first.isRead, isTrue);
    expect(chapters.first.isBookmarked, isTrue);
    expect(library.unavailableEntries, 1);

    // The applied state reads back unchanged, so the next pass uploads nothing new.
    final again = await library.snapshot(remote);
    final next = SyncMerger.merge(
      SyncMerger.capture(remote, SyncOptions.mangayomi.captureSnapshot(again, remote), 'pc', 4),
      remote,
    );
    expect(SyncMerger.merge(next, remote), SyncMerger.merge(remote, remote));
  });

  test('a local edit made while HTTP was in flight is kept', () async {
    final manga = addManga();
    final chapter = addChapter(manga, '/c/1', page: '3');
    final observed = await library.snapshot(const SyncDocument());
    isar.writeTxnSync(() => isar.chapters.putSync(chapter..lastPageRead = '7'));
    await library.apply(
      SyncDocument(
        mangas: [
          observed.mangas.single.copyWith(
            chapters: const [
              SyncChapter(url: '/c/1', name: '/c/1', position: SyncValue(ReadingPosition(page: 20), SyncVersion(9, 'phone'))),
            ],
          ),
        ],
      ),
      observed,
    );
    expect(isar.chapters.getSync(chapter.id!)!.lastPageRead, '7');
  });
}
