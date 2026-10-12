import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mangayomi/services/mihon_sync/service.dart';

/// Settings for synchronizing with Mihon Sync (Android) through a WebDAV folder.
class MihonSyncScreen extends StatefulWidget {
  const MihonSyncScreen({super.key});

  @override
  State<MihonSyncScreen> createState() => _MihonSyncScreenState();
}

class _MihonSyncScreenState extends State<MihonSyncScreen> {
  final _service = MihonSyncService.instance;
  final _endpoint = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _testMessage;
  bool _obscure = true;

  static const _intervals = {0: 'Solo manual', 15: '15 minutos', 30: '30 minutos', 60: '1 hora', 180: '3 horas'};

  @override
  void initState() {
    super.initState();
    final settings = _service.settings.value;
    _endpoint.text = settings.endpoint;
    _username.text = settings.username;
    _service.readPassword().then((value) {
      if (mounted) _password.text = value;
    });
  }

  @override
  void dispose() {
    _endpoint.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _run(String working, Future<String> Function() action) async {
    setState(() {
      _busy = true;
      _testMessage = working;
    });
    String message;
    try {
      message = await action();
    } catch (error) {
      message = '${describeSyncError(error)}\n${syncDiagnostic(error)}';
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _testMessage = message;
    });
  }

  String _formatDate(int millis) {
    if (millis <= 0) return 'nunca';
    final date = DateTime.fromMillisecondsSinceEpoch(millis);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${date.year}-${two(date.month)}-${two(date.day)} ${two(date.hour)}:${two(date.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Mihon Sync (WebDAV)')),
      body: ValueListenableBuilder<MihonSyncSettings>(
        valueListenable: _service.settings,
        builder: (context, settings, _) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Sincroniza la biblioteca, capítulos leídos, página, marcadores, categorías e historial '
              'con Mihon Sync en Android usando la misma carpeta WebDAV. Solo se comparten mangas de '
              'extensiones de Mihon. Las tiendas, extensiones, migraciones, trackers y ajustes del lector '
              'de Mihon se conservan sin cambios.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _endpoint,
              enabled: !_busy,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'URL de la carpeta WebDAV (https://…)',
                helperText: 'La misma carpeta que en Mihon Sync, p. ej. …/remote.php/dav/files/USUARIO/mihon-sync/',
                helperMaxLines: 3,
              ),
            ),
            TextField(
              controller: _username,
              enabled: !_busy,
              decoration: const InputDecoration(labelText: 'Usuario'),
            ),
            TextField(
              controller: _password,
              enabled: !_busy,
              obscureText: _obscure,
              decoration: InputDecoration(
                labelText: 'Contraseña (de aplicación)',
                suffixIcon: IconButton(
                  icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonal(
                  onPressed: _busy
                      ? null
                      : () => _run('Probando conexión…', () async {
                          await _service.testConnection(_endpoint.text, _username.text, _password.text);
                          return 'Conexión correcta: la carpeta existe y el servidor protege los cambios simultáneos.';
                        }),
                  child: const Text('Probar conexión'),
                ),
                OutlinedButton(
                  onPressed: _busy
                      ? null
                      : () => _run('Creando carpeta…', () async {
                          await _service.createFolder(_endpoint.text, _username.text, _password.text);
                          return 'Carpeta lista.';
                        }),
                  child: const Text('Crear carpeta'),
                ),
                FilledButton(
                  onPressed: _busy
                      ? null
                      : () => _run('Guardando…', () async {
                          await _service.saveConnection(_endpoint.text, _username.text, _password.text);
                          return 'Guardado.';
                        }),
                  child: const Text('Guardar'),
                ),
              ],
            ),
            if (_testMessage != null) ...[
              const SizedBox(height: 8),
              SelectableText(_testMessage!),
            ],
            const Divider(height: 32),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Sincronización activada'),
              subtitle: const Text('Al abrir la app, al cerrar el lector y cada cierto tiempo mientras está abierta.'),
              value: settings.enabled,
              onChanged: settings.endpoint.isEmpty ? null : _service.setEnabled,
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Sincronizar automáticamente cada'),
              trailing: DropdownButton<int>(
                value: _intervals.containsKey(settings.intervalMinutes) ? settings.intervalMinutes : 15,
                items: [
                  for (final entry in _intervals.entries)
                    DropdownMenuItem(value: entry.key, child: Text(entry.value)),
                ],
                onChanged: (value) {
                  if (value != null) _service.setInterval(value);
                },
              ),
            ),
            ValueListenableBuilder<MihonSyncStatus>(
              valueListenable: _service.status,
              builder: (context, status, _) => Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(status.message, style: theme.textTheme.titleSmall),
                      if (status.notes != null) ...[
                        const SizedBox(height: 4),
                        Text(status.notes!),
                      ],
                      const SizedBox(height: 4),
                      Text('Última sincronización correcta: ${_formatDate(settings.lastSuccess)}'),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        children: [
                          FilledButton(
                            onPressed: settings.endpoint.isEmpty || status.state == MihonSyncState.running
                                ? null
                                : () => _service.syncNow(),
                            child: const Text('Sincronizar ahora'),
                          ),
                          if (status.diagnostic != null)
                            OutlinedButton(
                              onPressed: () => Clipboard.setData(ClipboardData(text: status.diagnostic!)),
                              child: const Text('Copiar diagnóstico'),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
