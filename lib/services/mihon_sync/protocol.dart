// Mihon Sync document model, wire-compatible with Mihon Sync 0.7.2 (document schema 4).
//
// The JSON layout mirrors the kotlinx.serialization classes of the Android app:
// fields equal to their default value may be omitted, unknown keys are ignored,
// and every required field is always written. Equality is structural, like
// Kotlin data classes, because the session compares whole documents.

import 'package:collection/collection.dart';

const _listEq = ListEquality<Object?>();
const _setEq = SetEquality<Object?>();
const _mapEq = MapEquality<Object?, Object?>();

/// Thrown for documents that are not valid Mihon Sync documents.
class SyncFormatException implements Exception {
  final String message;
  SyncFormatException(this.message);
  @override
  String toString() => 'SyncFormatException: $message';
}

void syncRequire(bool condition, [String message = 'invalid sync data']) {
  if (!condition) throw SyncFormatException(message);
}

Map<String, dynamic> _object(Object? value, String name) {
  if (value is Map) return value.cast<String, dynamic>();
  throw SyncFormatException('$name must be an object');
}

List<dynamic> _list(Object? value, String name) {
  if (value is List) return value;
  throw SyncFormatException('$name must be an array');
}

String _string(Object? value, String name) {
  if (value is String) return value;
  throw SyncFormatException('$name must be a string');
}

String? _stringOrNull(Object? value, String name) {
  if (value == null || value is String) return value as String?;
  throw SyncFormatException('$name must be a string');
}

int _int(Object? value, String name) {
  if (value is int) return value;
  if (value is double && value == value.truncateToDouble() && value.isFinite) {
    return value.toInt();
  }
  throw SyncFormatException('$name must be an integer');
}

double _double(Object? value, String name) {
  if (value is num) return value.toDouble();
  throw SyncFormatException('$name must be a number');
}

bool _bool(Object? value, String name) {
  if (value is bool) return value;
  throw SyncFormatException('$name must be a boolean');
}

T _required<T>(Map<String, dynamic> json, String key, T Function(Object?) read) {
  if (!json.containsKey(key)) throw SyncFormatException('missing $key');
  return read(json[key]);
}

T _optional<T>(
  Map<String, dynamic> json,
  String key,
  T fallback,
  T Function(Object?) read,
) => json.containsKey(key) ? read(json[key]) : fallback;

/// Compares strings like Kotlin's String.compareTo (UTF-16 code units).
int compareStrings(String a, String b) => a.compareTo(b);

class SyncKey {
  final int source;
  final String url;
  const SyncKey(this.source, this.url);

  factory SyncKey.fromJson(Object? json) {
    final map = _object(json, 'key');
    return SyncKey(
      _required(map, 'source', (v) => _int(v, 'source')),
      _required(map, 'url', (v) => _string(v, 'url')),
    );
  }

  Map<String, dynamic> toJson() => {'source': source, 'url': url};

  @override
  bool operator ==(Object other) =>
      other is SyncKey && other.source == source && other.url == url;

  @override
  int get hashCode => Object.hash(source, url);

  @override
  String toString() => 'SyncKey($source, $url)';
}

int compareKeys(SyncKey a, SyncKey b) {
  final bySource = a.source.compareTo(b.source);
  return bySource != 0 ? bySource : compareStrings(a.url, b.url);
}

class SyncVersion implements Comparable<SyncVersion> {
  final int time;
  final String device;
  const SyncVersion([this.time = 0, this.device = '']);

  static const zero = SyncVersion();

  factory SyncVersion.fromJson(Object? json) {
    final map = _object(json, 'version');
    return SyncVersion(
      _optional(map, 'time', 0, (v) => _int(v, 'time')),
      _optional(map, 'device', '', (v) => _string(v, 'device')),
    );
  }

  Map<String, dynamic> toJson({bool defaults = false}) => {
    if (defaults || time != 0) 'time': time,
    if (defaults || device.isNotEmpty) 'device': device,
  };

  @override
  int compareTo(SyncVersion other) {
    final byTime = time.compareTo(other.time);
    return byTime != 0 ? byTime : compareStrings(device, other.device);
  }

  bool operator >=(SyncVersion other) => compareTo(other) >= 0;
  bool operator >(SyncVersion other) => compareTo(other) > 0;

  @override
  bool operator ==(Object other) =>
      other is SyncVersion && other.time == time && other.device == device;

  @override
  int get hashCode => Object.hash(time, device);

  @override
  String toString() => 'SyncVersion($time, $device)';
}

class SyncValue<T> {
  final T value;
  final SyncVersion version;
  const SyncValue(this.value, [this.version = SyncVersion.zero]);

  static SyncValue<T> fromJson<T>(Object? json, T Function(Object?) read) {
    final map = _object(json, 'value');
    return SyncValue(
      _required(map, 'value', read),
      _optional(map, 'version', SyncVersion.zero, SyncVersion.fromJson),
    );
  }

  Map<String, dynamic> toJson(
    Object? Function(T) write, {
    bool defaults = false,
  }) => {
    'value': write(value),
    if (defaults || version != SyncVersion.zero)
      'version': version.toJson(defaults: defaults),
  };

  @override
  bool operator ==(Object other) =>
      other is SyncValue &&
      other.version == version &&
      _deepEquals(other.value, value);

  @override
  int get hashCode => Object.hash(_deepHash(value), version);

  @override
  String toString() => 'SyncValue($value, $version)';
}

bool _deepEquals(Object? a, Object? b) {
  if (a is List && b is List) return _listEq.equals(a, b);
  if (a is Set && b is Set) return _setEq.equals(a, b);
  if (a is Map && b is Map) return _mapEq.equals(a, b);
  return a == b;
}

int _deepHash(Object? value) {
  if (value is List) return _listEq.hash(value);
  if (value is Set) return _setEq.hash(value);
  if (value is Map) return _mapEq.hash(value);
  return value.hashCode;
}

class ReadingPosition {
  final bool read;
  final int page;
  const ReadingPosition({this.read = false, this.page = 0});

  static const unread = ReadingPosition();

  factory ReadingPosition.fromJson(Object? json) {
    final map = _object(json, 'position');
    return ReadingPosition(
      read: _optional(map, 'read', false, (v) => _bool(v, 'read')),
      page: _optional(map, 'page', 0, (v) => _int(v, 'page')),
    );
  }

  Map<String, dynamic> toJson({bool defaults = false}) => {
    if (defaults || read) 'read': read,
    if (defaults || page != 0) 'page': page,
  };

  @override
  bool operator ==(Object other) =>
      other is ReadingPosition && other.read == read && other.page == page;

  @override
  int get hashCode => Object.hash(read, page);

  @override
  String toString() => 'ReadingPosition($read, $page)';
}

class SyncChapter {
  final String url;
  final String name;
  final double number;
  final int sourceOrder;
  final String? scanlator;
  final SyncValue<ReadingPosition> position;
  final SyncValue<bool> bookmark;
  final int lastReadAt;

  const SyncChapter({
    required this.url,
    required this.name,
    this.number = -1.0,
    this.sourceOrder = 0,
    this.scanlator,
    this.position = const SyncValue(ReadingPosition.unread),
    this.bookmark = const SyncValue(false),
    this.lastReadAt = 0,
  });

  SyncChapter copyWith({
    String? name,
    double? number,
    int? sourceOrder,
    String? scanlator,
    bool clearScanlator = false,
    SyncValue<ReadingPosition>? position,
    SyncValue<bool>? bookmark,
    int? lastReadAt,
  }) => SyncChapter(
    url: url,
    name: name ?? this.name,
    number: number ?? this.number,
    sourceOrder: sourceOrder ?? this.sourceOrder,
    scanlator: clearScanlator ? null : (scanlator ?? this.scanlator),
    position: position ?? this.position,
    bookmark: bookmark ?? this.bookmark,
    lastReadAt: lastReadAt ?? this.lastReadAt,
  );

  factory SyncChapter.fromJson(Object? json) {
    final map = _object(json, 'chapter');
    return SyncChapter(
      url: _required(map, 'url', (v) => _string(v, 'url')),
      name: _required(map, 'name', (v) => _string(v, 'name')),
      number: _optional(map, 'number', -1.0, (v) => _double(v, 'number')),
      sourceOrder: _optional(map, 'sourceOrder', 0, (v) => _int(v, 'sourceOrder')),
      scanlator: _optional<String?>(map, 'scanlator', null, (v) => _stringOrNull(v, 'scanlator')),
      position: _optional(
        map,
        'position',
        const SyncValue(ReadingPosition.unread),
        (v) => SyncValue.fromJson(v, ReadingPosition.fromJson),
      ),
      bookmark: _optional(
        map,
        'bookmark',
        const SyncValue(false),
        (v) => SyncValue.fromJson(v, (b) => _bool(b, 'bookmark')),
      ),
      lastReadAt: _optional(map, 'lastReadAt', 0, (v) => _int(v, 'lastReadAt')),
    );
  }

  Map<String, dynamic> toJson({bool defaults = false}) => {
    'url': url,
    'name': name,
    if (defaults || number != -1.0) 'number': number,
    if (defaults || sourceOrder != 0) 'sourceOrder': sourceOrder,
    if (defaults || scanlator != null) 'scanlator': scanlator,
    if (defaults || position != const SyncValue(ReadingPosition.unread))
      'position': position.toJson(
        (p) => p.toJson(defaults: defaults),
        defaults: defaults,
      ),
    if (defaults || bookmark != const SyncValue(false))
      'bookmark': bookmark.toJson((b) => b, defaults: defaults),
    if (defaults || lastReadAt != 0) 'lastReadAt': lastReadAt,
  };

  @override
  bool operator ==(Object other) =>
      other is SyncChapter &&
      other.url == url &&
      other.name == name &&
      other.number == number &&
      other.sourceOrder == sourceOrder &&
      other.scanlator == scanlator &&
      other.position == position &&
      other.bookmark == bookmark &&
      other.lastReadAt == lastReadAt;

  @override
  int get hashCode => Object.hash(
    url,
    name,
    number,
    sourceOrder,
    scanlator,
    position,
    bookmark,
    lastReadAt,
  );
}

class SyncReaderSettings {
  final int viewerFlags;
  final int chapterFlags;
  const SyncReaderSettings(this.viewerFlags, this.chapterFlags);

  static const unset = SyncReaderSettings(0, 0);

  static SyncReaderSettings? fromJson(Object? json) {
    if (json == null) return null;
    final map = _object(json, 'reader');
    return SyncReaderSettings(
      _required(map, 'viewerFlags', (v) => _int(v, 'viewerFlags')),
      _required(map, 'chapterFlags', (v) => _int(v, 'chapterFlags')),
    );
  }

  Map<String, dynamic> toJson() => {
    'viewerFlags': viewerFlags,
    'chapterFlags': chapterFlags,
  };

  @override
  bool operator ==(Object other) =>
      other is SyncReaderSettings &&
      other.viewerFlags == viewerFlags &&
      other.chapterFlags == chapterFlags;

  @override
  int get hashCode => Object.hash(viewerFlags, chapterFlags);
}

/// Tracker links are shared by Mihon. This app keeps them unchanged.
class SyncTrack {
  final int trackerId;
  final int remoteId;
  final String title;
  final double lastChapterRead;
  final int totalChapters;
  final int status;
  final double score;
  final String remoteUrl;
  final int? startDate;
  final int? finishDate;
  final bool private;

  const SyncTrack({
    required this.trackerId,
    required this.remoteId,
    required this.title,
    required this.lastChapterRead,
    required this.totalChapters,
    required this.status,
    required this.score,
    required this.remoteUrl,
    this.startDate,
    this.finishDate,
    this.private = false,
  });

  factory SyncTrack.fromJson(Object? json) {
    final map = _object(json, 'track');
    return SyncTrack(
      trackerId: _required(map, 'trackerId', (v) => _int(v, 'trackerId')),
      remoteId: _required(map, 'remoteId', (v) => _int(v, 'remoteId')),
      title: _required(map, 'title', (v) => _string(v, 'title')),
      lastChapterRead: _required(
        map,
        'lastChapterRead',
        (v) => _double(v, 'lastChapterRead'),
      ),
      totalChapters: _required(map, 'totalChapters', (v) => _int(v, 'totalChapters')),
      status: _required(map, 'status', (v) => _int(v, 'status')),
      score: _required(map, 'score', (v) => _double(v, 'score')),
      remoteUrl: _required(map, 'remoteUrl', (v) => _string(v, 'remoteUrl')),
      startDate: _optional<int?>(map, 'startDate', null, (v) => v == null ? null : _int(v, 'startDate')),
      finishDate: _optional<int?>(map, 'finishDate', null, (v) => v == null ? null : _int(v, 'finishDate')),
      private: _optional(map, 'private', false, (v) => _bool(v, 'private')),
    );
  }

  Map<String, dynamic> toJson({bool defaults = false}) => {
    'trackerId': trackerId,
    'remoteId': remoteId,
    'title': title,
    'lastChapterRead': lastChapterRead,
    'totalChapters': totalChapters,
    'status': status,
    'score': score,
    'remoteUrl': remoteUrl,
    if (defaults || startDate != null) 'startDate': startDate,
    if (defaults || finishDate != null) 'finishDate': finishDate,
    if (defaults || private) 'private': private,
  };

  @override
  bool operator ==(Object other) =>
      other is SyncTrack &&
      other.trackerId == trackerId &&
      other.remoteId == remoteId &&
      other.title == title &&
      other.lastChapterRead == lastChapterRead &&
      other.totalChapters == totalChapters &&
      other.status == status &&
      other.score == score &&
      other.remoteUrl == remoteUrl &&
      other.startDate == startDate &&
      other.finishDate == finishDate &&
      other.private == private;

  @override
  int get hashCode => Object.hash(
    trackerId,
    remoteId,
    title,
    lastChapterRead,
    totalChapters,
    status,
    score,
    remoteUrl,
    startDate,
    finishDate,
    private,
  );
}

class SyncManga {
  final SyncKey key;
  final String title;
  final String? thumbnail;
  final SyncValue<bool> favorite;
  final Map<String, SyncValue<bool>> categories;
  final List<SyncChapter> chapters;
  final SyncValue<SyncReaderSettings?> reader;
  final SyncValue<List<SyncTrack>> tracks;

  const SyncManga({
    required this.key,
    required this.title,
    this.thumbnail,
    this.favorite = const SyncValue(false),
    this.categories = const {},
    this.chapters = const [],
    this.reader = const SyncValue(null),
    this.tracks = const SyncValue(<SyncTrack>[]),
  });

  SyncManga copyWith({
    String? title,
    String? thumbnail,
    SyncValue<bool>? favorite,
    Map<String, SyncValue<bool>>? categories,
    List<SyncChapter>? chapters,
    SyncValue<SyncReaderSettings?>? reader,
    SyncValue<List<SyncTrack>>? tracks,
  }) => SyncManga(
    key: key,
    title: title ?? this.title,
    thumbnail: thumbnail ?? this.thumbnail,
    favorite: favorite ?? this.favorite,
    categories: categories ?? this.categories,
    chapters: chapters ?? this.chapters,
    reader: reader ?? this.reader,
    tracks: tracks ?? this.tracks,
  );

  factory SyncManga.fromJson(Object? json) {
    final map = _object(json, 'manga');
    final categories = <String, SyncValue<bool>>{};
    _optional<Map<String, dynamic>>(
      map,
      'categories',
      const {},
      (v) => _object(v, 'categories'),
    ).forEach((name, value) {
      categories[name] = SyncValue.fromJson(value, (b) => _bool(b, 'category'));
    });
    return SyncManga(
      key: _required(map, 'key', SyncKey.fromJson),
      title: _required(map, 'title', (v) => _string(v, 'title')),
      thumbnail: _optional<String?>(map, 'thumbnail', null, (v) => _stringOrNull(v, 'thumbnail')),
      favorite: _optional(
        map,
        'favorite',
        const SyncValue(false),
        (v) => SyncValue.fromJson(v, (b) => _bool(b, 'favorite')),
      ),
      categories: categories,
      chapters: _optional(map, 'chapters', const <dynamic>[], (v) => _list(v, 'chapters'))
          .map(SyncChapter.fromJson)
          .toList(),
      reader: _optional(
        map,
        'reader',
        const SyncValue<SyncReaderSettings?>(null),
        (v) => SyncValue.fromJson<SyncReaderSettings?>(v, SyncReaderSettings.fromJson),
      ),
      tracks: _optional(
        map,
        'tracks',
        const SyncValue(<SyncTrack>[]),
        (v) => SyncValue.fromJson<List<SyncTrack>>(
          v,
          (list) => _list(list, 'tracks').map(SyncTrack.fromJson).toList(),
        ),
      ),
    );
  }

  Map<String, dynamic> toJson({bool defaults = false}) => {
    'key': key.toJson(),
    'title': title,
    if (defaults || thumbnail != null) 'thumbnail': thumbnail,
    if (defaults || favorite != const SyncValue(false))
      'favorite': favorite.toJson((b) => b, defaults: defaults),
    if (defaults || categories.isNotEmpty)
      'categories': {
        for (final entry in categories.entries)
          entry.key: entry.value.toJson((b) => b, defaults: defaults),
      },
    if (defaults || chapters.isNotEmpty)
      'chapters': [for (final c in chapters) c.toJson(defaults: defaults)],
    if (defaults || reader != const SyncValue<SyncReaderSettings?>(null))
      'reader': reader.toJson((r) => r?.toJson(), defaults: defaults),
    if (defaults || tracks != const SyncValue(<SyncTrack>[]))
      'tracks': tracks.toJson(
        (list) => [for (final t in list) t.toJson(defaults: defaults)],
        defaults: defaults,
      ),
  };

  @override
  bool operator ==(Object other) =>
      other is SyncManga &&
      other.key == key &&
      other.title == title &&
      other.thumbnail == thumbnail &&
      other.favorite == favorite &&
      _mapEq.equals(other.categories, categories) &&
      _listEq.equals(other.chapters, chapters) &&
      other.reader == reader &&
      other.tracks == tracks;

  @override
  int get hashCode => Object.hash(
    key,
    title,
    thumbnail,
    favorite,
    _mapEq.hash(categories),
    _listEq.hash(chapters),
    reader,
    tracks,
  );
}

class SyncCategory {
  final String id;
  final SyncValue<String> name;
  final SyncValue<int> order;
  final SyncValue<bool> deleted;

  const SyncCategory({
    required this.id,
    required this.name,
    this.order = const SyncValue(0),
    this.deleted = const SyncValue(false),
  });

  SyncCategory copyWith({
    SyncValue<String>? name,
    SyncValue<int>? order,
    SyncValue<bool>? deleted,
  }) => SyncCategory(
    id: id,
    name: name ?? this.name,
    order: order ?? this.order,
    deleted: deleted ?? this.deleted,
  );

  factory SyncCategory.fromJson(Object? json) {
    final map = _object(json, 'category');
    return SyncCategory(
      id: _required(map, 'id', (v) => _string(v, 'id')),
      name: _required(map, 'name', (v) => SyncValue.fromJson(v, (s) => _string(s, 'name'))),
      order: _optional(
        map,
        'order',
        const SyncValue(0),
        (v) => SyncValue.fromJson(v, (n) => _int(n, 'order')),
      ),
      deleted: _optional(
        map,
        'deleted',
        const SyncValue(false),
        (v) => SyncValue.fromJson(v, (b) => _bool(b, 'deleted')),
      ),
    );
  }

  Map<String, dynamic> toJson({bool defaults = false}) => {
    'id': id,
    'name': name.toJson((s) => s, defaults: defaults),
    if (defaults || order != const SyncValue(0))
      'order': order.toJson((n) => n, defaults: defaults),
    if (defaults || deleted != const SyncValue(false))
      'deleted': deleted.toJson((b) => b, defaults: defaults),
  };

  @override
  bool operator ==(Object other) =>
      other is SyncCategory &&
      other.id == id &&
      other.name == name &&
      other.order == order &&
      other.deleted == deleted;

  @override
  int get hashCode => Object.hash(id, name, order, deleted);
}

class SyncExtensionStore {
  final String indexUrl;
  final String signingKey;
  const SyncExtensionStore(this.indexUrl, this.signingKey);

  factory SyncExtensionStore.fromJson(Object? json) {
    final map = _object(json, 'store');
    return SyncExtensionStore(
      _required(map, 'indexUrl', (v) => _string(v, 'indexUrl')),
      _required(map, 'signingKey', (v) => _string(v, 'signingKey')),
    );
  }

  Map<String, dynamic> toJson() => {'indexUrl': indexUrl, 'signingKey': signingKey};

  @override
  bool operator ==(Object other) =>
      other is SyncExtensionStore &&
      other.indexUrl == indexUrl &&
      other.signingKey == signingKey;

  @override
  int get hashCode => Object.hash(indexUrl, signingKey);
}

class SyncExtension {
  final String pkgName;
  final String name;
  final int versionCode;
  final String signingKey;
  const SyncExtension(this.pkgName, this.name, this.versionCode, this.signingKey);

  factory SyncExtension.fromJson(Object? json) {
    final map = _object(json, 'extension');
    return SyncExtension(
      _required(map, 'pkgName', (v) => _string(v, 'pkgName')),
      _required(map, 'name', (v) => _string(v, 'name')),
      _required(map, 'versionCode', (v) => _int(v, 'versionCode')),
      _required(map, 'signingKey', (v) => _string(v, 'signingKey')),
    );
  }

  Map<String, dynamic> toJson() => {
    'pkgName': pkgName,
    'name': name,
    'versionCode': versionCode,
    'signingKey': signingKey,
  };

  @override
  bool operator ==(Object other) =>
      other is SyncExtension &&
      other.pkgName == pkgName &&
      other.name == name &&
      other.versionCode == versionCode &&
      other.signingKey == signingKey;

  @override
  int get hashCode => Object.hash(pkgName, name, versionCode, signingKey);
}

/// Mihon's shared inventory of extension stores and extensions. Mangayomi keeps it unchanged.
class SyncCatalog {
  final List<SyncExtensionStore> stores;
  final List<SyncExtension> extensions;
  const SyncCatalog([this.stores = const [], this.extensions = const []]);

  static final _package = RegExp(r'^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$');
  static final _signature = RegExp(r'^[0-9a-f]{64}$');

  static bool isSigningKey(String value) => _signature.hasMatch(value);

  static bool isHttpsUrl(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null) return false;
    return value.length <= 16384 &&
        uri.scheme == 'https' &&
        uri.host.trim().isNotEmpty &&
        uri.userInfo.isEmpty &&
        !uri.hasQuery &&
        !uri.hasFragment &&
        (!uri.hasPort || (uri.port >= 1 && uri.port <= 65535));
  }

  void validate() {
    syncRequire(stores.length <= 2000 && extensions.length <= 10000);
    syncRequire(stores.toSet().length == stores.length);
    syncRequire(
      extensions.map((e) => '${e.pkgName}\n${e.signingKey}').toSet().length ==
          extensions.length,
    );
    for (final store in stores) {
      syncRequire(isHttpsUrl(store.indexUrl) && isSigningKey(store.signingKey));
    }
    for (final extension in extensions) {
      syncRequire(
        extension.pkgName.length <= 255 && _package.hasMatch(extension.pkgName),
      );
      syncRequire(
        extension.name.trim().isNotEmpty &&
            extension.name.length <= 1024 &&
            extension.versionCode >= 0,
      );
      syncRequire(isSigningKey(extension.signingKey));
    }
  }

  SyncCatalog merge(SyncCatalog other) {
    validate();
    other.validate();
    final mergedStores = <SyncExtensionStore>{...stores, ...other.stores}.toList()
      ..sort((a, b) {
        final byUrl = compareStrings(a.indexUrl, b.indexUrl);
        return byUrl != 0 ? byUrl : compareStrings(a.signingKey, b.signingKey);
      });
    final grouped = <String, SyncExtension>{};
    for (final extension in [...extensions, ...other.extensions]) {
      final key = '${extension.pkgName}\n${extension.signingKey}';
      final current = grouped[key];
      if (current == null ||
          extension.versionCode > current.versionCode ||
          (extension.versionCode == current.versionCode &&
              compareStrings(extension.name, current.name) > 0)) {
        grouped[key] = extension;
      }
    }
    final mergedExtensions = grouped.values.toList()
      ..sort((a, b) {
        final byPkg = compareStrings(a.pkgName, b.pkgName);
        return byPkg != 0 ? byPkg : compareStrings(a.signingKey, b.signingKey);
      });
    return SyncCatalog(mergedStores, mergedExtensions)..validate();
  }

  factory SyncCatalog.fromJson(Object? json) {
    final map = _object(json, 'catalog');
    return SyncCatalog(
      _optional(map, 'stores', const <dynamic>[], (v) => _list(v, 'stores'))
          .map(SyncExtensionStore.fromJson)
          .toList(),
      _optional(map, 'extensions', const <dynamic>[], (v) => _list(v, 'extensions'))
          .map(SyncExtension.fromJson)
          .toList(),
    );
  }

  Map<String, dynamic> toJson({bool defaults = false}) => {
    if (defaults || stores.isNotEmpty) 'stores': [for (final s in stores) s.toJson()],
    if (defaults || extensions.isNotEmpty)
      'extensions': [for (final e in extensions) e.toJson()],
  };

  bool get isEmpty => stores.isEmpty && extensions.isEmpty;

  @override
  bool operator ==(Object other) =>
      other is SyncCatalog &&
      _listEq.equals(other.stores, stores) &&
      _listEq.equals(other.extensions, extensions);

  @override
  int get hashCode => Object.hash(_listEq.hash(stores), _listEq.hash(extensions));
}

/// A migration made in Mihon. Mangayomi keeps these records unchanged.
class SyncMigration {
  final SyncKey from;
  final SyncKey to;
  final SyncVersion version;
  final bool replace;
  const SyncMigration(this.from, this.to, this.version, {this.replace = true});

  static const limit = 10000;

  void validate() {
    syncRequire(from != to);
    for (final key in [from, to]) {
      syncRequire(key.url.trim().isNotEmpty && key.url.length <= 16384);
    }
    syncRequire(version.time >= 0 && version.device.length <= 256);
  }

  static int _compare(SyncMigration a, SyncMigration b) {
    var result = a.version.compareTo(b.version);
    if (result != 0) return result;
    result = a.from.source.compareTo(b.from.source);
    if (result != 0) return result;
    result = compareStrings(a.from.url, b.from.url);
    if (result != 0) return result;
    result = a.to.source.compareTo(b.to.source);
    if (result != 0) return result;
    return compareStrings(a.to.url, b.to.url);
  }

  static List<SyncMigration> merge(
    List<SyncMigration> first,
    List<SyncMigration> second,
  ) {
    final grouped = <String, SyncMigration>{};
    for (final record in [...first, ...second]) {
      final key = '${record.from.source} ${record.from.url}\n${record.to.source} ${record.to.url}';
      final current = grouped[key];
      if (current == null) {
        grouped[key] = record;
        continue;
      }
      final byVersion = record.version.compareTo(current.version);
      final better =
          byVersion > 0 || (byVersion == 0 && record.replace && !current.replace);
      if (better) grouped[key] = record;
    }
    final result = grouped.values.toList()..sort(_compare);
    return result.length > limit ? result.sublist(result.length - limit) : result;
  }

  factory SyncMigration.fromJson(Object? json) {
    final map = _object(json, 'migration');
    return SyncMigration(
      _required(map, 'from', SyncKey.fromJson),
      _required(map, 'to', SyncKey.fromJson),
      _required(map, 'version', SyncVersion.fromJson),
      replace: _optional(map, 'replace', true, (v) => _bool(v, 'replace')),
    );
  }

  Map<String, dynamic> toJson({bool defaults = false}) => {
    'from': from.toJson(),
    'to': to.toJson(),
    'version': version.toJson(defaults: defaults),
    if (defaults || !replace) 'replace': replace,
  };

  @override
  bool operator ==(Object other) =>
      other is SyncMigration &&
      other.from == from &&
      other.to == to &&
      other.version == version &&
      other.replace == replace;

  @override
  int get hashCode => Object.hash(from, to, version, replace);
}

class SyncDocument {
  static const schemaVersion = 4;
  static final _categoryId = RegExp(r'^[a-zA-Z0-9_-]{1,128}$');

  final int schema;
  final List<SyncManga> mangas;
  final Set<String> categoryNames;
  final SyncCatalog catalog;
  final List<SyncMigration> migrations;
  final List<SyncCategory> categoryDefinitions;

  const SyncDocument({
    this.schema = schemaVersion,
    this.mangas = const [],
    this.categoryNames = const {},
    this.catalog = const SyncCatalog(),
    this.migrations = const [],
    this.categoryDefinitions = const [],
  });

  SyncDocument copyWith({
    int? schema,
    List<SyncManga>? mangas,
    Set<String>? categoryNames,
    SyncCatalog? catalog,
    List<SyncMigration>? migrations,
    List<SyncCategory>? categoryDefinitions,
  }) => SyncDocument(
    schema: schema ?? this.schema,
    mangas: mangas ?? this.mangas,
    categoryNames: categoryNames ?? this.categoryNames,
    catalog: catalog ?? this.catalog,
    migrations: migrations ?? this.migrations,
    categoryDefinitions: categoryDefinitions ?? this.categoryDefinitions,
  );

  void validate() {
    syncRequire(schema >= 1 && schema <= schemaVersion, 'Unsupported sync format');
    catalog.validate();
    syncRequire(schema != 1 || catalog.isEmpty);
    syncRequire(schema >= 3 || migrations.isEmpty);
    syncRequire(migrations.length <= SyncMigration.limit);
    syncRequire(
      migrations.map((m) => '${m.from.source} ${m.from.url}\n${m.to.source} ${m.to.url}').toSet().length ==
          migrations.length,
    );
    for (final migration in migrations) {
      migration.validate();
    }
    syncRequire(schema >= 4 || categoryDefinitions.isEmpty);
    syncRequire(
      categoryDefinitions.length <= 10000 &&
          categoryDefinitions.map((c) => c.id).toSet().length == categoryDefinitions.length,
    );
    for (final category in categoryDefinitions) {
      syncRequire(_categoryId.hasMatch(category.id));
      syncRequire(
        category.name.value.trim().isNotEmpty &&
            category.name.value.length <= 1024 &&
            category.order.value >= 0,
      );
      syncRequire(
        category.name.version.time >= 0 &&
            category.order.version.time >= 0 &&
            category.deleted.version.time >= 0,
      );
    }
    syncRequire(
      mangas.length <= 100000 && mangas.map((m) => m.key).toSet().length == mangas.length,
    );
    syncRequire(categoryNames.every((n) => n.trim().isNotEmpty && n.length <= 1024));
    for (final manga in mangas) {
      syncRequire(manga.key.url.trim().isNotEmpty && manga.key.url.length <= 16384);
      syncRequire(manga.favorite.version.time >= 0);
      syncRequire(
        schema >= 4 || (manga.reader.value == null && manga.tracks.value.isEmpty),
      );
      syncRequire(
        manga.reader.version.time >= 0 &&
            manga.tracks.version.time >= 0 &&
            manga.tracks.value.length <= 100,
      );
      syncRequire(
        manga.tracks.value.map((t) => t.trackerId).toSet().length ==
            manga.tracks.value.length,
      );
      for (final track in manga.tracks.value) {
        syncRequire(
          track.lastChapterRead.isFinite && track.score.isFinite && track.title.length <= 1024,
        );
        syncRequire(track.remoteUrl.length <= 16384 && track.totalChapters >= 0);
      }
      syncRequire(manga.categories.keys.every((n) => n.trim().isNotEmpty && n.length <= 1024));
      syncRequire(manga.categories.values.every((v) => v.version.time >= 0));
      syncRequire(
        manga.chapters.map((c) => c.url).toSet().length == manga.chapters.length,
      );
      for (final chapter in manga.chapters) {
        syncRequire(
          chapter.url.trim().isNotEmpty &&
              chapter.url.length <= 16384 &&
              chapter.number.isFinite,
        );
        syncRequire(chapter.position.value.page >= 0 && chapter.position.version.time >= 0);
        syncRequire(chapter.bookmark.version.time >= 0 && chapter.lastReadAt >= 0);
      }
    }
  }

  factory SyncDocument.fromJson(Object? json) {
    final map = _object(json, 'document');
    return SyncDocument(
      schema: _optional(map, 'schema', schemaVersion, (v) => _int(v, 'schema')),
      mangas: _optional(map, 'mangas', const <dynamic>[], (v) => _list(v, 'mangas'))
          .map(SyncManga.fromJson)
          .toList(),
      categoryNames: _optional(
        map,
        'categoryNames',
        const <dynamic>[],
        (v) => _list(v, 'categoryNames'),
      ).map((n) => _string(n, 'categoryName')).toSet(),
      catalog: _optional(map, 'catalog', const SyncCatalog(), SyncCatalog.fromJson),
      migrations: _optional(map, 'migrations', const <dynamic>[], (v) => _list(v, 'migrations'))
          .map(SyncMigration.fromJson)
          .toList(),
      categoryDefinitions: _optional(
        map,
        'categoryDefinitions',
        const <dynamic>[],
        (v) => _list(v, 'categoryDefinitions'),
      ).map(SyncCategory.fromJson).toList(),
    );
  }

  /// [defaults] false gives the compact wire form used by Mihon; the schema is always written.
  Map<String, dynamic> toJson({bool defaults = false}) => {
    'schema': schema,
    if (defaults || mangas.isNotEmpty)
      'mangas': [for (final m in mangas) m.toJson(defaults: defaults)],
    if (defaults || categoryNames.isNotEmpty) 'categoryNames': categoryNames.toList(),
    if (defaults || !catalog.isEmpty) 'catalog': catalog.toJson(defaults: defaults),
    if (defaults || migrations.isNotEmpty)
      'migrations': [for (final m in migrations) m.toJson(defaults: defaults)],
    if (defaults || categoryDefinitions.isNotEmpty)
      'categoryDefinitions': [
        for (final c in categoryDefinitions) c.toJson(defaults: defaults),
      ],
  };

  @override
  bool operator ==(Object other) =>
      other is SyncDocument &&
      other.schema == schema &&
      _listEq.equals(other.mangas, mangas) &&
      _setEq.equals(other.categoryNames, categoryNames) &&
      other.catalog == catalog &&
      _listEq.equals(other.migrations, migrations) &&
      _listEq.equals(other.categoryDefinitions, categoryDefinitions);

  @override
  int get hashCode => Object.hash(
    schema,
    _listEq.hash(mangas),
    _setEq.hash(categoryNames),
    catalog,
    _listEq.hash(migrations),
    _listEq.hash(categoryDefinitions),
  );
}

/// Values read from the local database. Versions are assigned by the merger.
class SyncSnapshot {
  final List<SyncManga> mangas;
  final Set<String> categoryNames;
  final SyncCatalog catalog;
  final List<SyncMigration> migrations;
  final List<SyncCategory> categoryDefinitions;

  const SyncSnapshot({
    required this.mangas,
    this.categoryNames = const {},
    this.catalog = const SyncCatalog(),
    this.migrations = const [],
    this.categoryDefinitions = const [],
  });

  SyncSnapshot copyWith({
    List<SyncManga>? mangas,
    Set<String>? categoryNames,
    SyncCatalog? catalog,
    List<SyncMigration>? migrations,
    List<SyncCategory>? categoryDefinitions,
  }) => SyncSnapshot(
    mangas: mangas ?? this.mangas,
    categoryNames: categoryNames ?? this.categoryNames,
    catalog: catalog ?? this.catalog,
    migrations: migrations ?? this.migrations,
    categoryDefinitions: categoryDefinitions ?? this.categoryDefinitions,
  );
}
