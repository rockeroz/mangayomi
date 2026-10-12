import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mangayomi/services/mihon_sync/merger.dart';
import 'package:mangayomi/services/mihon_sync/protocol.dart';
import 'package:mangayomi/services/mihon_sync/remote.dart';
import 'package:mangayomi/services/mihon_sync/session.dart';

const _key = '9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2';

/// A document written the way Mihon Sync 0.7.2 (kotlinx.serialization, defaults omitted) writes it.
const _mihonDocument = '''
{"schema":4,"mangas":[{"key":{"source":2499283573021220255,"url":"/manga/abc"},"title":"Book",
"thumbnail":"https://example.org/c.jpg","favorite":{"value":true,"version":{"time":1700000000000,"device":"phone"}},
"categories":{"name-c8da565936564fe670ae244a5cffba73840c78f78da95d68528fb60874f61e9b":{"value":true,"version":{"time":1700000000001,"device":"phone"}}},
"chapters":[{"url":"/c/1","name":"Ch 1","number":1.0,"position":{"value":{"read":true,"page":17},"version":{"time":1700000000002,"device":"phone"}},"lastReadAt":1700000000500},
{"url":"/c/2","name":"Ch 2","number":2.0,"sourceOrder":1,"scanlator":"Group","bookmark":{"value":true,"version":{"time":1700000000003,"device":"phone"}}}],
"reader":{"value":{"viewerFlags":1,"chapterFlags":2},"version":{"time":1700000000004,"device":"phone"}},
"tracks":{"value":[{"trackerId":2,"remoteId":55,"title":"X","lastChapterRead":3.0,"totalChapters":10,"status":1,"score":8.5,"remoteUrl":"https://anilist.co/manga/55"}],"version":{"time":1700000000005,"device":"phone"}}}],
"catalog":{"stores":[{"indexUrl":"https://raw.githubusercontent.com/keiyoushi/extensions/repo/repo.json","signingKey":"$_key"}],
"extensions":[{"pkgName":"eu.kanade.tachiyomi.extension.es.example","name":"Example","versionCode":5,"signingKey":"$_key"}]},
"migrations":[{"from":{"source":1,"url":"/a"},"to":{"source":2,"url":"/b"},"version":{"time":1700000000006,"device":"phone"}}],
"categoryDefinitions":[{"id":"name-c8da565936564fe670ae244a5cffba73840c78f78da95d68528fb60874f61e9b","name":{"value":"Leyendo","version":{"time":1700000000001,"device":"phone"}},"order":{"value":1}}]}
''';

SyncManga _manga({int page = 0, String url = '/book', bool favorite = true}) => SyncManga(
  key: SyncKey(1, url),
  title: 'Book',
  favorite: SyncValue(favorite),
  chapters: [
    SyncChapter(url: '/chapter', name: 'Chapter', position: SyncValue(ReadingPosition(page: page))),
  ],
);

class _Library implements SyncLibraryRepository {
  List<SyncManga> mangas;
  _Library(this.mangas);

  @override
  Future<SyncSnapshot> snapshot(SyncDocument known) async => SyncSnapshot(mangas: mangas);

  @override
  Future<void> apply(SyncDocument remote, SyncSnapshot observed) async {
    mangas = remote.mangas;
  }

  int page() => mangas.single.chapters.single.position.value.page;

  void setPage(int page) {
    mangas = [
      for (final manga in mangas)
        manga.copyWith(
          chapters: [
            for (final chapter in manga.chapters)
              chapter.copyWith(position: SyncValue(ReadingPosition(page: page))),
          ],
        ),
    ];
  }
}

class _Journal implements SyncJournalStore {
  SyncJournal state = const SyncJournal();
  @override
  SyncJournal read() => state;
  @override
  void write(SyncJournal journal) => state = journal;
}

class _Cache implements IncrementalCacheStore {
  IncrementalCache state = const IncrementalCache();
  @override
  IncrementalCache read() => state;
  @override
  void write(IncrementalCache cache) => state = cache;
}

/// In-memory WebDAV server with strong ETags and conditional requests, like Nextcloud.
class _Server {
  final files = <String, (List<int>, int)>{};
  var downloads = 0;
  var notModified = 0;
  var writes = 0;
  var version = 0;

  late final client = MockClient((request) async {
    final name = request.url.pathSegments.last;
    final current = files[name];
    final etag = current == null ? null : '"${current.$2}"';
    switch (request.method) {
      case 'GET':
        if (current == null) return http.Response('', 404);
        if (request.headers['If-None-Match'] == etag) {
          notModified++;
          return http.Response('', 304, headers: {'etag': etag!});
        }
        downloads++;
        return http.Response.bytes(current.$1, 200, headers: {'etag': etag!});
      case 'PUT':
        final ifMatch = request.headers['If-Match'];
        final ifNone = request.headers['If-None-Match'];
        if ((ifMatch != null && ifMatch != etag) || (ifNone == '*' && current != null)) {
          return http.Response('', 412);
        }
        writes++;
        files[name] = (request.bodyBytes, ++version);
        return http.Response('', current == null ? 201 : 204, headers: {'etag': '"$version"'});
      case 'PROPFIND':
        return http.Response('', 207);
      case 'DELETE':
        files.remove(name);
        return http.Response('', 204);
      default:
        return http.Response('', 405);
    }
  });

  WebDavSyncTransport transport() =>
      WebDavSyncTransport('https://example.org/dav/mihon-sync/', 'user', 'password', client: client);
}

class _Device {
  final _Server server;
  final _Library library;
  final _Journal journal = _Journal();
  final _Cache cache = _Cache();
  final String id;
  bool reading = false;
  _Device(this.server, this.library, this.id);

  Future<bool> sync() => MihonSyncSession(
    repository: library,
    remote: IncrementalWebDavStore(server.transport(), cache),
    store: journal,
    device: id,
    readerOpen: () => reading,
  ).sync();
}

void main() {
  group('Mihon Sync format', () {
    test('documents written by Mihon decode, validate and round-trip', () {
      final document = SyncDocument.fromJson(jsonDecode(_mihonDocument));
      document.validate();
      final manga = document.mangas.single;
      expect(manga.key, const SyncKey(2499283573021220255, '/manga/abc'));
      expect(manga.chapters.first.position.value, const ReadingPosition(read: true, page: 17));
      expect(manga.chapters.last.number, 2.0);
      expect(manga.chapters.last.scanlator, 'Group');
      expect(manga.chapters.last.bookmark.value, isTrue);
      expect(manga.reader.value, const SyncReaderSettings(1, 2));
      expect(manga.tracks.value.single.score, 8.5);
      expect(document.catalog.extensions.single.versionCode, 5);
      expect(document.migrations.single.replace, isTrue);
      expect(document.categoryDefinitions.single.order.value, 1);
      final again = SyncDocument.fromJson(jsonDecode(jsonEncode(document.toJson())));
      expect(again, document);
      expect(SyncDocument.fromJson(jsonDecode(jsonEncode(document.toJson(defaults: true)))), document);
    });

    test('compact encoding omits defaults like kotlinx and always writes the schema', () {
      const document = SyncDocument();
      expect(jsonEncode(document.toJson()), '{"schema":4}');
      final chapter = const SyncChapter(url: '/c', name: 'C').toJson();
      expect(chapter, {'url': '/c', 'name': 'C'});
      expect(jsonEncode(const SyncChapter(url: '/c', name: 'C', number: 3).toJson()), contains('"number":3.0'));
    });

    test('legacy category ids are SHA-256 of the name', () {
      expect(
        SyncCategories.legacyId('Reading'),
        'name-463816d07097e1a7cf27b86cf03082ee49f6ce2d87663cd27a24d7254a83e76a',
      );
    });

    test('Mihon-only data is kept when Mangayomi captures its own library', () {
      final remote = SyncDocument.fromJson(jsonDecode(_mihonDocument));
      final local = SyncSnapshot(
        mangas: [
          SyncManga(
            key: remote.mangas.single.key,
            title: 'Book',
            favorite: const SyncValue(true),
            categories: {remote.categoryDefinitions.single.id: const SyncValue(true)},
            chapters: [
              const SyncChapter(
                url: '/c/1',
                name: 'Ch 1',
                number: 1,
                position: SyncValue(ReadingPosition(read: true, page: 17)),
              ),
              const SyncChapter(
                url: '/c/2',
                name: 'Ch 2',
                number: 2,
                sourceOrder: 1,
                scanlator: 'Group',
                position: SyncValue(ReadingPosition(page: 4)),
                bookmark: SyncValue(true),
              ),
            ],
          ),
        ],
        categoryDefinitions: remote.categoryDefinitions,
      );
      const options = SyncOptions.mangayomi;
      final candidate = SyncMerger.merge(
        SyncMerger.capture(remote, options.captureSnapshot(local, remote), 'pc', 1800000000000),
        remote,
      );
      final merged = SyncMerger.merge(candidate, remote);
      expect(merged.catalog, remote.catalog);
      expect(merged.migrations, remote.migrations);
      expect(merged.mangas.single.reader, remote.mangas.single.reader);
      expect(merged.mangas.single.tracks, remote.mangas.single.tracks);
      expect(merged.mangas.single.chapters.first.lastReadAt, 1700000000500);
      final edited = merged.mangas.single.chapters.last.position;
      expect(edited.value, const ReadingPosition(page: 4));
      expect(edited.version, const SyncVersion(1800000000000, 'pc'));
      expect(merged.mangas.single.chapters.first.position, remote.mangas.single.chapters.first.position);
    });

    test('a new device with unread chapters does not reset remote progress', () {
      final remote = SyncMerger.capture(
        const SyncDocument(),
        SyncSnapshot(mangas: [_manga(page: 20)]),
        'phone',
        1000,
      );
      final fresh = SyncMerger.capture(const SyncDocument(), SyncSnapshot(mangas: [_manga()]), 'pc', 2000);
      expect(SyncMerger.merge(fresh, remote).mangas.single.chapters.single.position.value.page, 20);
    });

    test('delta carries only changed chapters and merges back to the full document', () {
      final before = SyncMerger.capture(
        const SyncDocument(),
        SyncSnapshot(mangas: [_manga(page: 1), _manga(url: '/other', page: 2)]),
        'phone',
        1000,
      );
      final after = SyncMerger.capture(
        before,
        SyncSnapshot(mangas: [_manga(page: 9), _manga(url: '/other', page: 2)]),
        'phone',
        2000,
      );
      final delta = SyncDelta.between(before, after);
      expect(delta.mangas.length, 1);
      expect(SyncMerger.merge(before, delta), SyncMerger.merge(before, after));
    });
  });

  group('Mihon Sync over WebDAV', () {
    test('two devices converge, and an unchanged document is not downloaded again', () async {
      final server = _Server();
      final phone = _Device(server, _Library([_manga(page: 3)]), 'phone');
      final pc = _Device(server, _Library([]), 'pc');
      expect(await phone.sync(), isTrue);
      expect(server.files.containsKey('mihon-sync-v2-manifest.json'), isTrue);
      expect(server.files.containsKey('mihon-sync-v1.json'), isTrue);
      expect(await pc.sync(), isTrue);
      expect(pc.library.page(), 3);
      final downloads = server.downloads;
      final writes = server.writes;
      expect(await pc.sync(), isTrue);
      expect(server.downloads, downloads);
      expect(server.writes, writes);
      expect(server.notModified, greaterThan(0));
      pc.library.setPage(9);
      expect(await pc.sync(), isTrue);
      expect(await phone.sync(), isTrue);
      expect(phone.library.page(), 9);
      // The page change travels as a small change part referenced by the manifest.
      final manifest = jsonDecode(utf8.decode(server.files['mihon-sync-v2-manifest.json']!.$1)) as Map;
      expect((manifest['changes'] as List).length, 1);
    });

    test('remote changes wait while a reader is open', () async {
      final server = _Server();
      final phone = _Device(server, _Library([_manga(page: 1)]), 'phone');
      final pc = _Device(server, _Library([]), 'pc');
      await phone.sync();
      await pc.sync();
      phone.library.setPage(8);
      await phone.sync();
      pc.reading = true;
      expect(await pc.sync(), isFalse);
      expect(pc.library.page(), 1);
      pc.reading = false;
      expect(await pc.sync(), isTrue);
      expect(pc.library.page(), 8);
    });

    test('a newly linked library takes the server state for entries it already has', () async {
      final server = _Server();
      final phone = _Device(server, _Library([_manga(page: 12)]), 'phone');
      await phone.sync();
      // An older copy of the same entry, plus one that only this device has.
      final pc = _Device(server, _Library([_manga(page: 5), _manga(url: '/only-pc', page: 2)]), 'pc');
      expect(await pc.sync(), isTrue);
      expect(pc.library.mangas.firstWhere((m) => m.key.url == '/book').chapters.single.position.value.page, 12);
      await phone.sync();
      expect(phone.library.mangas.map((m) => m.key.url).toSet(), {'/book', '/only-pc'});
      expect(phone.library.mangas.firstWhere((m) => m.key.url == '/book').chapters.single.position.value.page, 12);
    });

    test('a manifest published by Mihon is read', () async {
      final server = _Server();
      final document = SyncDocument.fromJson(jsonDecode(_mihonDocument));
      final plain = utf8.encode(_mihonDocument);
      final digest = sha256.convert(plain).toString();
      final part = 'mihon-base-$digest.json.gz';
      server.files[part] = (gzip.encode(plain), ++server.version);
      // kotlinx omits format = 1 and empty changes.
      server.files['mihon-sync-v2-manifest.json'] = (
        utf8.encode('{"base":{"file":"$part","sha256":"$digest"}}'),
        ++server.version,
      );
      final pc = _Device(server, _Library([]), 'pc');
      expect(await pc.sync(), isTrue);
      final received = pc.library.mangas.single;
      expect(received.key, document.mangas.single.key);
      expect(received.chapters, document.mangas.single.chapters);
      expect(received.categories, document.mangas.single.categories);
      // Mihon-only groups are not applied here but stay in the shared document.
      expect(pc.journal.state.baseline, document);
      expect(server.writes, 0);
    });

    test('many changes compact into a new base', () async {
      final server = _Server();
      final phone = _Device(server, _Library([_manga(page: 0)]), 'phone');
      await phone.sync();
      for (var page = 1; page <= IncrementalWebDavStore.maxChanges + 1; page++) {
        phone.library.setPage(page);
        expect(await phone.sync(), isTrue);
      }
      final manifest = jsonDecode(utf8.decode(server.files['mihon-sync-v2-manifest.json']!.$1)) as Map;
      expect(manifest['changes'], isNull);
      final pc = _Device(server, _Library([]), 'pc');
      await pc.sync();
      expect(pc.library.page(), IncrementalWebDavStore.maxChanges + 1);
    });

    test('a server that ignores conditional writes is rejected by the connection test', () async {
      final files = <String, String>{};
      final client = MockClient((request) async {
        final name = request.url.pathSegments.last;
        if (request.method == 'PUT') {
          files[name] = request.body;
          return http.Response('', 201, headers: {'etag': '"1"'});
        }
        if (request.method == 'GET') {
          final body = files[name];
          return body == null
              ? http.Response('', 404)
              : http.Response(body, 200, headers: {'etag': '"1"'});
        }
        return http.Response('', 204);
      });
      final transport = WebDavSyncTransport(
        'https://example.org/dav/mihon-sync',
        'user',
        'password',
        client: client,
      );
      await expectLater(
        transport.testConnection(),
        throwsA(
          isA<SyncFailure>().having((f) => f.reason, 'reason', SyncFailureReason.unsupportedServer),
        ),
      );
    });

    test('folder URL keeps encoded paths and appends the shared file name', () {
      expect(
        WebDavSyncTransport.fileUrl('https://example.org/dav/a%20b').toString(),
        'https://example.org/dav/a%20b/mihon-sync-v1.json',
      );
      expect(
        () => WebDavSyncTransport.fileUrl('http://example.org/dav'),
        throwsA(isA<SyncFailure>()),
      );
    });
  });
}
