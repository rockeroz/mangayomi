// WebDAV access for Mihon Sync, compatible with Mihon Sync 0.7.2.
//
// Every write is conditional (If-Match / If-None-Match: *) and every read checks for a strong
// ETag, so concurrent devices never overwrite each other's changes. The library itself is
// published as immutable gzip parts referenced by a small manifest (format 1).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show Random;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:mangayomi/services/mihon_sync/merger.dart';
import 'package:mangayomi/services/mihon_sync/protocol.dart';

enum SyncFailureReason {
  settings,
  authentication,
  permission,
  server,
  unsupportedServer,
  format,
  tooLarge,
  busy,
  network,
}

class SyncFailure implements Exception {
  final SyncFailureReason reason;
  final int? httpStatus;
  final String? method;
  final Object? cause;
  SyncFailure(this.reason, {this.httpStatus, this.method, this.cause});

  @override
  String toString() =>
      'SyncFailure(${reason.name}${httpStatus != null ? ', HTTP $httpStatus' : ''}'
      '${method != null ? ' $method' : ''})';
}

class RemoteSyncFile {
  final String? content;
  final String? etag;

  /// The parsed form of [content], when the store already has it.
  final SyncDocument? document;
  const RemoteSyncFile(this.content, this.etag, {this.document});
}

class RemoteBinaryFile {
  final Uint8List? content;
  final String? etag;
  const RemoteBinaryFile(this.content, this.etag);
}

class RemoteWrite {
  final bool accepted;
  final String? etag;
  const RemoteWrite(this.accepted, [this.etag]);
}

const maxSyncBytes = 20 * 1024 * 1024;

bool isStrongEtag(String? etag) =>
    etag != null &&
    etag.length >= 2 &&
    !etag.startsWith('W/') &&
    etag.startsWith('"') &&
    etag.endsWith('"');

class WebDavSyncTransport {
  final Uri target;
  final String _authorization;
  final http.Client _client;
  final bool _ownsClient;

  static const legacyFile = 'mihon-sync-v1.json';
  static const _timeout = Duration(seconds: 180);

  WebDavSyncTransport(String endpoint, String username, String password, {http.Client? client})
    : target = fileUrl(endpoint),
      _authorization = 'Basic ${base64.encode(utf8.encode('$username:$password'))}',
      _client = client ?? http.Client(),
      _ownsClient = client == null;

  void close() {
    if (_ownsClient) _client.close();
  }

  /// The shared document location inside the WebDAV folder.
  static Uri fileUrl(String endpoint) {
    final uri = Uri.tryParse(endpoint.trim());
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw SyncFailure(SyncFailureReason.settings);
    }
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    return uri.replace(pathSegments: [...segments, legacyFile]);
  }

  Uri resourceUrl(String name) {
    if (!RegExp(r'^[A-Za-z0-9_.-]{1,180}$').hasMatch(name)) {
      throw SyncFailure(SyncFailureReason.settings);
    }
    final segments = target.pathSegments.toList()..removeLast();
    return target.replace(pathSegments: [...segments, name]);
  }

  Uri get folderUrl {
    final segments = target.pathSegments.toList()..removeLast();
    return target.replace(pathSegments: [...segments, '']);
  }

  Future<_Response> _send(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
    List<int>? body,
    String contentType = 'application/octet-stream',
    Duration? timeout,
  }) async {
    final request = http.Request(method, url)
      ..followRedirects = false
      ..headers['Authorization'] = _authorization
      ..headers['Cache-Control'] = 'no-cache, no-store'
      ..headers.addAll(headers);
    if (body != null) {
      request.bodyBytes = body;
      request.headers['Content-Type'] = contentType;
    }
    try {
      final streamed = await _client.send(request).timeout(timeout ?? _timeout);
      final builder = BytesBuilder(copy: false);
      await for (final chunk in streamed.stream.timeout(timeout ?? _timeout)) {
        builder.add(chunk);
        if (builder.length > maxSyncBytes) {
          throw SyncFailure(SyncFailureReason.tooLarge);
        }
      }
      return _Response(streamed.statusCode, streamed.headers, builder.takeBytes());
    } on SyncFailure {
      rethrow;
    } on TimeoutException catch (error) {
      throw SyncFailure(SyncFailureReason.network, method: method, cause: error);
    } on SocketException catch (error) {
      throw SyncFailure(SyncFailureReason.network, method: method, cause: error);
    } on HandshakeException catch (error) {
      throw SyncFailure(SyncFailureReason.network, method: method, cause: error);
    } on http.ClientException catch (error) {
      throw SyncFailure(SyncFailureReason.network, method: method, cause: error);
    }
  }

  Never _fail(int status, String method) {
    switch (status) {
      case 401:
        throw SyncFailure(SyncFailureReason.authentication, httpStatus: 401, method: method);
      case 403:
        throw SyncFailure(SyncFailureReason.permission, httpStatus: 403, method: method);
      default:
        throw SyncFailure(SyncFailureReason.server, httpStatus: status, method: method);
    }
  }

  /// Null when [knownEtag] still matches (HTTP 304).
  Future<RemoteBinaryFile?> readResource(String name, {String? knownEtag}) =>
      _read(resourceUrl(name), knownEtag);

  Future<RemoteBinaryFile?> _read(Uri url, String? knownEtag) async {
    final response = await _send(
      'GET',
      url,
      headers: {if (knownEtag != null) 'If-None-Match': knownEtag},
    );
    switch (response.status) {
      case 304:
        if (knownEtag != null) return null;
        _fail(304, 'GET');
      case 404:
        return const RemoteBinaryFile(null, null);
      case 200:
        final etag = response.header('etag');
        if (!isStrongEtag(etag)) {
          throw SyncFailure(SyncFailureReason.unsupportedServer);
        }
        return RemoteBinaryFile(response.body, etag);
      default:
        _fail(response.status, 'GET');
    }
  }

  Future<RemoteWrite> putResource(String name, List<int> bytes, String? etag) =>
      _write(resourceUrl(name), bytes, etag);

  Future<RemoteWrite> _write(
    Uri url,
    List<int> bytes,
    String? etag, {
    String contentType = 'application/octet-stream',
  }) async {
    if (bytes.length > maxSyncBytes) throw SyncFailure(SyncFailureReason.tooLarge);
    final response = await _send(
      'PUT',
      url,
      headers: etag == null ? {'If-None-Match': '*'} : {'If-Match': etag},
      body: bytes,
      contentType: contentType,
    );
    switch (response.status) {
      case 200:
      case 201:
      case 204:
        final newEtag = response.header('etag');
        return RemoteWrite(true, isStrongEtag(newEtag) ? newEtag : null);
      case 412:
        return const RemoteWrite(false);
      default:
        _fail(response.status, 'PUT');
    }
  }

  /// The legacy single-file document, read as text.
  Future<RemoteSyncFile> read() async {
    final file = (await _read(target, null))!;
    return RemoteSyncFile(file.content == null ? null : utf8.decode(file.content!), file.etag);
  }

  Future<RemoteSyncFile?> readIfChanged(String knownEtag) async {
    final file = await _read(target, knownEtag);
    if (file == null) return null;
    return RemoteSyncFile(file.content == null ? null : utf8.decode(file.content!), file.etag);
  }

  Future<RemoteWrite> put(String content, String? etag) =>
      _write(target, utf8.encode(content), etag, contentType: 'application/json; charset=utf-8');

  /// Account and folder access, checked separately from write access.
  Future<void> checkFolder() async {
    final response = await _send(
      'PROPFIND',
      folderUrl,
      headers: {'Depth': '0'},
      body: const [],
      contentType: 'application/xml',
    );
    if (response.status == 200 || response.status == 207) return;
    _fail(response.status, 'PROPFIND');
  }

  Future<void> createFolder() async {
    final response = await _send('MKCOL', folderUrl);
    if (response.status != 201 && response.status != 405) {
      _fail(response.status, 'MKCOL');
    }
    await checkFolder();
  }

  /// Same checks as Mihon Sync 0.7.2: a temporary file must reject stale conditional writes.
  Future<void> testConnection() async {
    final id = _randomId();
    final probe = resourceUrl('mihon-probe-$id.json');
    final payload = '{"probe":"$id"}';
    final rejected = '{"probe":"$id","revision":"rejected"}';
    final accepted = '{"probe":"$id","revision":"accepted"}';
    Future<RemoteBinaryFile> readProbe() async => (await _read(probe, null))!;
    String? text(RemoteBinaryFile file) =>
        file.content == null ? null : utf8.decode(file.content!);
    var created = false;
    try {
      if (!(await _write(probe, utf8.encode(payload), null)).accepted) {
        throw SyncFailure(SyncFailureReason.server);
      }
      created = true;
      final initial = await readProbe();
      if (text(initial) != payload) throw SyncFailure(SyncFailureReason.unsupportedServer);
      // A server that ignores conditional PUTs can silently lose changes from other devices.
      if ((await _write(probe, utf8.encode(rejected), '"missing-$id"')).accepted) {
        throw SyncFailure(SyncFailureReason.unsupportedServer);
      }
      if (text(await readProbe()) != payload) {
        throw SyncFailure(SyncFailureReason.unsupportedServer);
      }
      if ((await _write(probe, utf8.encode(rejected), null)).accepted) {
        throw SyncFailure(SyncFailureReason.unsupportedServer);
      }
      final unchanged = await readProbe();
      if (text(unchanged) != payload) throw SyncFailure(SyncFailureReason.unsupportedServer);
      if (!(await _write(probe, utf8.encode(accepted), unchanged.etag)).accepted) {
        throw SyncFailure(SyncFailureReason.server);
      }
      if (text(await readProbe()) != accepted) {
        throw SyncFailure(SyncFailureReason.unsupportedServer);
      }
    } finally {
      if (created) {
        try {
          await _send('DELETE', probe, timeout: const Duration(seconds: 5));
        } catch (_) {
          // The probe holds no library data. A failed cleanup does not affect synchronization.
        }
      }
    }
  }

  static String _randomId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
        '${hex.substring(16, 20)}-${hex.substring(20)}';
  }
}

class _Response {
  final int status;
  final Map<String, String> headers;
  final Uint8List body;
  _Response(this.status, this.headers, this.body);

  String? header(String name) => headers[name.toLowerCase()];
}

/// The interface the session uses to read and publish the shared document.
abstract class SyncRemoteStore {
  Future<RemoteSyncFile> read();

  /// Null when the document still has [knownEtag].
  Future<RemoteSyncFile?> readIfChanged(String knownEtag);

  Future<RemoteWrite> put(SyncDocument document, String? etag);

  bool needsInitialization() => false;
}

class SyncPart {
  final String file;
  final String sha256;
  const SyncPart(this.file, this.sha256);

  factory SyncPart.fromJson(Object? json) {
    if (json is! Map) throw SyncFormatException('part must be an object');
    final file = json['file'];
    final digest = json['sha256'];
    if (file is! String || digest is! String) throw SyncFormatException('invalid part');
    return SyncPart(file, digest);
  }

  Map<String, dynamic> toJson() => {'file': file, 'sha256': sha256};

  @override
  bool operator ==(Object other) =>
      other is SyncPart && other.file == file && other.sha256 == sha256;

  @override
  int get hashCode => Object.hash(file, sha256);
}

class SyncManifest {
  final int format;
  final SyncPart base;
  final List<SyncPart> changes;
  const SyncManifest({this.format = 1, required this.base, this.changes = const []});

  void validate() {
    syncRequire(format == 1 && changes.length <= 32);
    syncRequire(changes.toSet().length == changes.length);
    final digest = RegExp(r'^[0-9a-f]{64}$');
    for (final part in [...changes, base]) {
      syncRequire(digest.hasMatch(part.sha256));
      syncRequire(
        part.file == 'mihon-base-${part.sha256}.json.gz' ||
            part.file == 'mihon-change-${part.sha256}.json.gz',
      );
    }
  }

  factory SyncManifest.fromJson(Object? json) {
    if (json is! Map) throw SyncFormatException('manifest must be an object');
    final format = json['format'] ?? 1;
    if (format is! int) throw SyncFormatException('invalid manifest format');
    final changes = json['changes'] ?? const [];
    if (changes is! List) throw SyncFormatException('invalid manifest changes');
    return SyncManifest(
      format: format,
      base: SyncPart.fromJson(json['base']),
      changes: changes.map(SyncPart.fromJson).toList(),
    );
  }

  Map<String, dynamic> toJson() => {
    'base': base.toJson(),
    if (changes.isNotEmpty) 'changes': [for (final part in changes) part.toJson()],
  };

  @override
  bool operator ==(Object other) =>
      other is SyncManifest &&
      other.format == format &&
      other.base == base &&
      const _PartListEquality().equals(other.changes, changes);

  @override
  int get hashCode => Object.hash(format, base, Object.hashAll(changes));
}

class _PartListEquality {
  const _PartListEquality();
  bool equals(List<SyncPart> a, List<SyncPart> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Local copy of the remote document, derived from the manifest and its parts.
class IncrementalCache {
  final SyncManifest? manifest;
  final SyncDocument document;
  final String? etag;
  const IncrementalCache({this.manifest, this.document = const SyncDocument(), this.etag});

  factory IncrementalCache.fromJson(Object? json) {
    if (json is! Map) return const IncrementalCache();
    return IncrementalCache(
      manifest: json['manifest'] == null ? null : SyncManifest.fromJson(json['manifest']),
      document: json['document'] == null
          ? const SyncDocument()
          : SyncDocument.fromJson(json['document']),
      etag: json['etag'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    if (manifest != null) 'manifest': manifest!.toJson(),
    'document': document.toJson(),
    if (etag != null) 'etag': etag,
  };
}

abstract class IncrementalCacheStore {
  IncrementalCache read();
  void write(IncrementalCache cache);
}

SyncDocument decodeSyncDocument(String content) {
  try {
    final json = jsonDecode(content);
    syncRequire(json is Map && json.containsKey('schema'));
    return SyncDocument.fromJson(json)..validate();
  } on FormatException {
    throw SyncFailure(SyncFailureReason.format);
  } on SyncFormatException {
    throw SyncFailure(SyncFailureReason.format);
  }
}

String encodeSyncDocument(SyncDocument document) => jsonEncode(document.toJson());

/// Immutable compressed changes published by a small manifest PUT guarded by a strong ETag.
class IncrementalWebDavStore extends SyncRemoteStore {
  static const manifestFile = 'mihon-sync-v2-manifest.json';
  static const maxChanges = 32;
  static const _manifestPrefix = 'manifest|';
  static const _legacyPrefix = 'legacy|';

  final WebDavSyncTransport transport;
  final IncrementalCacheStore cacheStore;
  final void Function(int bytes) transferred;
  late IncrementalCache _cache;

  IncrementalWebDavStore(this.transport, this.cacheStore, {void Function(int)? transferred})
    : transferred = transferred ?? ((_) {}) {
    try {
      final cache = cacheStore.read();
      cache.manifest?.validate();
      cache.document.validate();
      _cache = cache;
    } catch (_) {
      // The cache is derived from the remote document; the independent journal stays intact.
      _cache = const IncrementalCache();
    }
  }

  @override
  bool needsInitialization() => _cache.manifest == null;

  @override
  Future<RemoteSyncFile> read() async => (await _fetch(null))!;

  @override
  Future<RemoteSyncFile?> readIfChanged(String knownEtag) => _fetch(knownEtag);

  Future<RemoteSyncFile?> _fetch(String? known) async {
    final rawEtag = known != null && known.startsWith(_manifestPrefix)
        ? known.substring(_manifestPrefix.length)
        : null;
    final file = await transport.readResource(manifestFile, knownEtag: rawEtag);
    if (file == null) {
      if (_cache.manifest != null && _cache.etag == rawEtag) return null;
      // A 304 proves the journal is current, but a missing cache still needs a base for delta writes.
      return _fetch(null);
    }
    if (file.content == null) {
      _cache = IncrementalCache(document: _cache.document);
      final RemoteSyncFile legacy;
      if (known != null && known.startsWith(_legacyPrefix)) {
        final changed = await transport.readIfChanged(known.substring(_legacyPrefix.length));
        if (changed == null) return null;
        legacy = changed;
      } else {
        legacy = await transport.read();
      }
      if (legacy.content != null) transferred(utf8.encode(legacy.content!).length);
      return RemoteSyncFile(
        legacy.content,
        legacy.etag == null ? null : '$_legacyPrefix${legacy.etag}',
      );
    }
    transferred(file.content!.length);
    final SyncManifest manifest;
    try {
      manifest = SyncManifest.fromJson(jsonDecode(utf8.decode(file.content!)))..validate();
    } on FormatException {
      throw SyncFailure(SyncFailureReason.format);
    } on SyncFormatException {
      throw SyncFailure(SyncFailureReason.format);
    }
    final previous = _cache.manifest;
    final reusable =
        previous != null &&
        previous.base == manifest.base &&
        previous.changes.every(manifest.changes.contains);
    var document = reusable ? _cache.document : await _download(manifest.base);
    final missing = reusable
        ? manifest.changes.where((c) => !previous!.changes.contains(c)).toList()
        : manifest.changes;
    for (final part in missing) {
      document = SyncMerger.merge(document, await _download(part));
    }
    final content = encodeSyncDocument(document);
    if (utf8.encode(content).length > maxSyncBytes) {
      throw SyncFailure(SyncFailureReason.tooLarge);
    }
    _cache = IncrementalCache(manifest: manifest, document: document, etag: file.etag);
    cacheStore.write(_cache);
    return RemoteSyncFile(
      content,
      file.etag == null ? null : '$_manifestPrefix${file.etag}',
      document: document,
    );
  }

  @override
  Future<RemoteWrite> put(SyncDocument document, String? etag) async {
    if (etag != null && etag.startsWith(_manifestPrefix)) {
      final cached = _cache.manifest;
      if (_cache.etag != etag.substring(_manifestPrefix.length) || cached == null) {
        return const RemoteWrite(false);
      }
      final SyncManifest manifest;
      if (cached.changes.length >= maxChanges) {
        manifest = SyncManifest(base: await _upload(document, base: true));
      } else {
        final change = await _upload(SyncDelta.between(_cache.document, document), base: false);
        manifest = SyncManifest(
          base: cached.base,
          changes: {...cached.changes, change}.toList(),
        );
      }
      return _publish(manifest, document, _cache.etag);
    }
    // Freeze the legacy file with schema 4 before publication. Older clients then stop without writing.
    final base = await _upload(document, base: true);
    final legacyEtag = etag != null && etag.startsWith(_legacyPrefix)
        ? etag.substring(_legacyPrefix.length)
        : null;
    final content = encodeSyncDocument(document);
    final frozen = await transport.put(content, legacyEtag);
    transferred(utf8.encode(content).length);
    if (!frozen.accepted) return const RemoteWrite(false);
    return _publish(SyncManifest(base: base), document, null);
  }

  Future<RemoteWrite> _publish(SyncManifest manifest, SyncDocument document, String? etag) async {
    final bytes = utf8.encode(jsonEncode(manifest.toJson()));
    final result = await transport.putResource(manifestFile, bytes, etag);
    transferred(bytes.length);
    if (result.accepted) {
      _cache = IncrementalCache(manifest: manifest, document: document, etag: result.etag);
      cacheStore.write(_cache);
    }
    return RemoteWrite(
      result.accepted,
      result.etag == null ? null : '$_manifestPrefix${result.etag}',
    );
  }

  Future<SyncPart> _upload(SyncDocument document, {required bool base}) async {
    final plain = utf8.encode(encodeSyncDocument(document));
    if (plain.length > maxSyncBytes) throw SyncFailure(SyncFailureReason.tooLarge);
    final digest = sha256.convert(plain).toString();
    final part = SyncPart('mihon-${base ? 'base' : 'change'}-$digest.json.gz', digest);
    final compressed = gzip.encode(plain);
    final written = await transport.putResource(part.file, compressed, null);
    transferred(compressed.length);
    if (!written.accepted) {
      // An identical immutable part may already exist after a lost response or another device's retry.
      if (await _download(part) != document) throw SyncFailure(SyncFailureReason.format);
    }
    return part;
  }

  Future<SyncDocument> _download(SyncPart part) async {
    final file = await transport.readResource(part.file);
    final compressed = file?.content;
    if (compressed == null) throw SyncFailure(SyncFailureReason.format);
    transferred(compressed.length);
    final List<int> plain;
    try {
      plain = _gunzipLimited(compressed);
    } on SyncFailure {
      rethrow;
    } catch (_) {
      throw SyncFailure(SyncFailureReason.format);
    }
    if (sha256.convert(plain).toString() != part.sha256) {
      throw SyncFailure(SyncFailureReason.format);
    }
    final String text;
    try {
      text = utf8.decode(plain);
    } on FormatException {
      throw SyncFailure(SyncFailureReason.format);
    }
    return decodeSyncDocument(text);
  }

  static List<int> _gunzipLimited(List<int> compressed) {
    final output = _LimitedSink();
    final input = gzip.decoder.startChunkedConversion(output);
    const chunk = 65536;
    for (var offset = 0; offset < compressed.length; offset += chunk) {
      final end = offset + chunk < compressed.length ? offset + chunk : compressed.length;
      input.add(compressed.sublist(offset, end));
    }
    input.close();
    return output.bytes.takeBytes();
  }
}

class _LimitedSink implements Sink<List<int>> {
  final bytes = BytesBuilder(copy: false);

  @override
  void add(List<int> data) {
    bytes.add(data);
    if (bytes.length > maxSyncBytes) throw SyncFailure(SyncFailureReason.tooLarge);
  }

  @override
  void close() {}
}
