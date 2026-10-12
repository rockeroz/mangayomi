// Runs Mihon Sync in Mangayomi: settings, scheduling and status.
//
// Synchronization runs when the app starts, periodically while it is open, when a reader
// closes, and on demand. Remote changes are not applied while a reader is open; they are
// kept in the journal and applied on the next pass.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mangayomi/services/mihon_sync/library.dart';
import 'package:mangayomi/services/mihon_sync/remote.dart';
import 'package:mangayomi/services/mihon_sync/session.dart';
import 'package:mangayomi/services/mihon_sync/storage.dart';

class MihonSyncSettings {
  final String endpoint;
  final String username;
  final bool enabled;
  final int intervalMinutes;
  final String deviceId;
  final String verifiedServer;
  final int verifiedAt;
  final int lastSuccess;

  const MihonSyncSettings({
    this.endpoint = '',
    this.username = '',
    this.enabled = false,
    this.intervalMinutes = 15,
    this.deviceId = '',
    this.verifiedServer = '',
    this.verifiedAt = 0,
    this.lastSuccess = 0,
  });

  MihonSyncSettings copyWith({
    String? endpoint,
    String? username,
    bool? enabled,
    int? intervalMinutes,
    String? deviceId,
    String? verifiedServer,
    int? verifiedAt,
    int? lastSuccess,
  }) => MihonSyncSettings(
    endpoint: endpoint ?? this.endpoint,
    username: username ?? this.username,
    enabled: enabled ?? this.enabled,
    intervalMinutes: intervalMinutes ?? this.intervalMinutes,
    deviceId: deviceId ?? this.deviceId,
    verifiedServer: verifiedServer ?? this.verifiedServer,
    verifiedAt: verifiedAt ?? this.verifiedAt,
    lastSuccess: lastSuccess ?? this.lastSuccess,
  );

  factory MihonSyncSettings.fromJson(Object? json) {
    if (json is! Map) return const MihonSyncSettings();
    T read<T>(String key, T fallback) => json[key] is T ? json[key] as T : fallback;
    return MihonSyncSettings(
      endpoint: read('endpoint', ''),
      username: read('username', ''),
      enabled: read('enabled', false),
      intervalMinutes: read('intervalMinutes', 15),
      deviceId: read('deviceId', ''),
      verifiedServer: read('verifiedServer', ''),
      verifiedAt: read('verifiedAt', 0),
      lastSuccess: read('lastSuccess', 0),
    );
  }

  Map<String, dynamic> toJson() => {
    'endpoint': endpoint,
    'username': username,
    'enabled': enabled,
    'intervalMinutes': intervalMinutes,
    'deviceId': deviceId,
    'verifiedServer': verifiedServer,
    'verifiedAt': verifiedAt,
    'lastSuccess': lastSuccess,
  };
}

enum MihonSyncState { idle, running, success, readerPending, error }

class MihonSyncStatus {
  final MihonSyncState state;
  final String message;
  final String? diagnostic;
  final String? notes;
  const MihonSyncStatus(this.state, this.message, {this.diagnostic, this.notes});
}

/// User-facing explanation of a failure.
String describeSyncError(Object error) {
  final failure = error is SyncStageFailure ? error.error : error;
  final stage = error is SyncStageFailure ? error.stage : null;
  if (failure is SyncFailure) {
    switch (failure.reason) {
      case SyncFailureReason.settings:
        return 'Revisa la dirección: debe empezar con https:// y no llevar usuario ni contraseña.';
      case SyncFailureReason.authentication:
        return 'Usuario o contraseña incorrectos (HTTP 401). En Nextcloud usa una contraseña de aplicación.';
      case SyncFailureReason.permission:
        return 'La cuenta no tiene permiso para esa carpeta (HTTP 403).';
      case SyncFailureReason.unsupportedServer:
        return 'El servidor no ofrece lo que la sincronización necesita (ETag fuerte y escrituras condicionales).';
      case SyncFailureReason.format:
        return 'Los datos del servidor no tienen un formato válido de Mihon Sync, o son de una versión más nueva.';
      case SyncFailureReason.tooLarge:
        return 'El documento supera el límite de 20 MiB.';
      case SyncFailureReason.busy:
        return 'Otro dispositivo estaba sincronizando al mismo tiempo. Se reintentará.';
      case SyncFailureReason.network:
        return 'No se pudo conectar con el servidor (red, certificado o tiempo de espera).';
      case SyncFailureReason.server:
        if (failure.httpStatus == 404) {
          return 'La carpeta no existe en el servidor (HTTP 404). Usa "Crear carpeta" o revisa la dirección.';
        }
        return 'El servidor respondió HTTP ${failure.httpStatus ?? '?'}'
            '${failure.method != null ? ' a ${failure.method}' : ''}.';
    }
  }
  if (failure is TimeoutException) return 'Se agotó el tiempo de espera.';
  return 'Error ${stage != null ? 'en ${stage.name}' : ''}: ${failure.runtimeType}.';
}

String syncDiagnostic(Object error) {
  final failure = error is SyncStageFailure ? error.error : error;
  final stage = error is SyncStageFailure ? error.stage.name : 'unknown';
  final buffer = StringBuffer('MANGAYOMI-MIHON-SYNC/1 stage=$stage type=${failure.runtimeType}');
  if (failure is SyncFailure) {
    buffer.write(' issue=${failure.reason.name}');
    if (failure.httpStatus != null) buffer.write(' HTTP=${failure.httpStatus}');
    if (failure.method != null) buffer.write(' method=${failure.method}');
    if (failure.cause != null) buffer.write(' cause=${failure.cause.runtimeType}');
  }
  return buffer.toString();
}

class MihonSyncService {
  static final MihonSyncService instance = MihonSyncService._();
  MihonSyncService._();

  static const _passwordKey = 'mihon_sync_password';
  static const _secureStorage = FlutterSecureStorage();

  final ValueNotifier<MihonSyncStatus> status = ValueNotifier(
    const MihonSyncStatus(MihonSyncState.idle, 'Sin sincronizar todavía.'),
  );
  final ValueNotifier<MihonSyncSettings> settings = ValueNotifier(const MihonSyncSettings());

  JsonFile? _settingsFile;
  Timer? _periodic;
  Timer? _pending;
  bool _running = false;
  bool _again = false;
  int _readers = 0;
  bool _started = false;

  bool get isReading => _readers > 0;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    try {
      await MihonSourceIds.instance.load();
      final directory = await mihonSyncDirectory();
      _settingsFile = JsonFile(File('${directory.path}${Platform.pathSeparator}settings.json'));
      settings.value = MihonSyncSettings.fromJson(_settingsFile!.read());
    } catch (_) {
      settings.value = const MihonSyncSettings();
    }
    _reschedule();
    if (settings.value.enabled) request(const Duration(seconds: 10));
  }

  void _save(MihonSyncSettings value) {
    settings.value = value;
    try {
      _settingsFile?.write(value.toJson());
    } catch (_) {
      // Kept in memory; written again on the next change.
    }
  }

  void _reschedule() {
    _periodic?.cancel();
    final minutes = settings.value.intervalMinutes;
    if (!settings.value.enabled || minutes <= 0) return;
    _periodic = Timer.periodic(Duration(minutes: minutes), (_) => request(Duration.zero));
  }

  Future<String> readPassword() async {
    try {
      return await _secureStorage.read(key: _passwordKey) ?? '';
    } catch (_) {
      return '';
    }
  }

  /// Saves the connection. A different account or folder gets its own journal automatically.
  Future<void> saveConnection(String endpoint, String username, String password) async {
    await _secureStorage.write(key: _passwordKey, value: password);
    _save(
      settings.value.copyWith(
        endpoint: endpoint.trim(),
        username: username,
        verifiedServer: '',
        verifiedAt: 0,
      ),
    );
    if (settings.value.enabled) request();
  }

  void setEnabled(bool enabled) {
    _save(settings.value.copyWith(enabled: enabled));
    _reschedule();
    if (enabled) request(Duration.zero);
  }

  void setInterval(int minutes) {
    _save(settings.value.copyWith(intervalMinutes: minutes));
    _reschedule();
  }

  /// Checks folder access and conditional writes with a temporary file, like Mihon's "Test connection".
  Future<void> testConnection(String endpoint, String username, String password) async {
    final transport = WebDavSyncTransport(endpoint, username, password);
    try {
      await syncStage(SyncStage.serverTest, () async {
        await transport.checkFolder();
        await transport.testConnection().timeout(const Duration(seconds: 40));
      });
    } finally {
      transport.close();
    }
  }

  Future<void> createFolder(String endpoint, String username, String password) async {
    final transport = WebDavSyncTransport(endpoint, username, password);
    try {
      await syncStage(SyncStage.serverTest, transport.createFolder);
    } finally {
      transport.close();
    }
  }

  void readerStarted() => _readers++;

  void readerStopped() {
    _readers = math.max(0, _readers - 1);
    // The reader saves its history while closing; give it a moment.
    request(const Duration(seconds: 3));
  }

  void request([Duration delay = const Duration(seconds: 3)]) {
    if (!settings.value.enabled || settings.value.endpoint.isEmpty) return;
    _pending?.cancel();
    _pending = Timer(delay, () => unawaited(syncNow()));
  }

  /// Runs a pass now; requests made meanwhile are grouped into one more pass.
  Future<void> syncNow() async {
    if (settings.value.endpoint.isEmpty) return;
    if (_running) {
      _again = true;
      return;
    }
    _running = true;
    try {
      do {
        _again = false;
        await _syncOnce();
      } while (_again);
    } finally {
      _running = false;
    }
  }

  Future<void> _syncOnce() async {
    final current = settings.value;
    status.value = const MihonSyncStatus(MihonSyncState.running, 'Sincronizando…');
    WebDavSyncTransport? transport;
    try {
      final password = await readPassword();
      transport = WebDavSyncTransport(current.endpoint, current.username, password);
      final accountKey = '${WebDavSyncTransport.fileUrl(current.endpoint)}\n${current.username}';
      final account = sha256.convert(utf8.encode(accountKey)).toString();
      final now = DateTime.now().millisecondsSinceEpoch;
      if (current.verifiedServer != account || now - current.verifiedAt < 0 || now - current.verifiedAt > 86400000) {
        final connection = transport;
        await syncStage(
          SyncStage.serverTest,
          () => connection.testConnection().timeout(const Duration(seconds: 40)),
        );
        _save(settings.value.copyWith(verifiedServer: account, verifiedAt: DateTime.now().millisecondsSinceEpoch));
      }
      var device = settings.value.deviceId;
      if (device.isEmpty) {
        device = newCategoryUid();
        _save(settings.value.copyWith(deviceId: device));
      }
      final directory = await mihonSyncDirectory();
      String path(String suffix) => '${directory.path}${Platform.pathSeparator}$account$suffix';
      final library = MangayomiSyncLibrary(
        CategoryIdentities(File(path('.categories.json'))),
        MihonSourceIds.instance,
      );
      var transferred = 0;
      final remote = IncrementalWebDavStore(
        transport,
        FileIncrementalCacheStore(File(path('.remote.json'))),
        transferred: (bytes) => transferred += bytes,
      );
      final session = MihonSyncSession(
        repository: library,
        remote: remote,
        store: FileJournalStore(File(path('.json'))),
        device: device,
        readerOpen: () => isReading,
        phase: (stage) => status.value = MihonSyncStatus(
          MihonSyncState.running,
          'Sincronizando… (${_phaseName(stage)})',
        ),
      );
      final applied = await session.sync();
      final notes = <String>[
        if (library.unmatchedEntries > 0)
          '${library.unmatchedEntries} mangas de la biblioteca no son de extensiones de Mihon o su fuente aún no se identifica; no se comparten.',
        if (library.unavailableEntries > 0)
          '${library.unavailableEntries} mangas recibidos usan fuentes que no aparecen en tus repositorios de Mangayomi; se aplicarán cuando añadas esos repositorios.',
        'Transferido: ${_formatBytes(transferred)}.',
      ];
      if (applied) {
        _save(settings.value.copyWith(lastSuccess: DateTime.now().millisecondsSinceEpoch));
        status.value = MihonSyncStatus(
          MihonSyncState.success,
          'Sincronizado.',
          notes: notes.join('\n'),
        );
      } else {
        status.value = MihonSyncStatus(
          MihonSyncState.readerPending,
          'Progreso enviado. Los cambios recibidos se aplicarán al cerrar el lector.',
          notes: notes.join('\n'),
        );
      }
    } catch (error) {
      status.value = MihonSyncStatus(
        MihonSyncState.error,
        describeSyncError(error),
        diagnostic: syncDiagnostic(error),
      );
    } finally {
      transport?.close();
    }
  }

  static String _phaseName(SyncStage stage) => switch (stage) {
    SyncStage.serverTest => 'probando el servidor',
    SyncStage.journalRead || SyncStage.localRead => 'leyendo la biblioteca',
    SyncStage.prepare || SyncStage.merge => 'combinando',
    SyncStage.journalWrite => 'guardando',
    SyncStage.download || SyncStage.decode => 'descargando',
    SyncStage.upload => 'subiendo',
    SyncStage.localApply => 'aplicando cambios',
  };

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
