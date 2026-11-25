import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../app_state.dart';
import 'nearby_sync.dart';
import 'server_sync.dart';

/// Строка «Рядом: 2 телефона» с точкой состояния. Нажатие — подробности.
class SyncBadge extends StatelessWidget {
  const SyncBadge({super.key, this.tripId, this.suffix = ''});
  final String? tripId;
  final String suffix;

  @override
  Widget build(BuildContext context) {
    final app = App.of(context);
    final sync = app.sync;
    final server = app.server;
    final cs = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: Listenable.merge([sync, server]),
      builder: (context, _) {
        final near = sync.state == SyncState.connected && sync.peersFor(tripId) > 0;
        final online = server.state == ServerState.online;
        final ok = near || online;
        final bad = !ok && (sync.state == SyncState.error || sync.state == SyncState.noPermission);
        final text = near ? sync.label(tripId) : (online ? 'Сервер: на связи' : sync.label(tripId));
        final color = ok ? cs.primary : (bad ? cs.error : cs.onSurfaceVariant);
        return InkWell(
          onTap: () => showSyncSheet(context),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
            const SizedBox(width: 6),
            Flexible(
              child: Text('$text$suffix',
                  overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant)),
            ),
          ]),
        );
      },
    );
  }
}

void showSyncSheet(BuildContext context) {
  final sync = App.read(context).sync;
  final server = App.read(context).server;
  showModalBottomSheet(
    context: context,
    showDragHandle: true,
    builder: (ctx) => ListenableBuilder(
      listenable: Listenable.merge([sync, server]),
      builder: (ctx, _) {
        final last = sync.lastSync;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(sync.label(), style: Theme.of(ctx).textTheme.titleMedium),
              const SizedBox(height: 4),
              const Text(
                'Телефоны группы сами находят друг друга рядом по Bluetooth и Wi‑Fi и обмениваются '
                'чатом, тратами и планом. Интернет не нужен.',
              ),
              const SizedBox(height: 12),
              Text(server.label, style: Theme.of(ctx).textTheme.titleMedium),
              const SizedBox(height: 4),
              const Text(
                'Когда группа не рядом, изменения идут через сервер Roamly в ЕС. '
                'Сервер не может их прочитать: всё зашифровано ключом поездки из QR.',
              ),
              if (last != null) ...[
                const SizedBox(height: 8),
                Text('Последний обмен: ${TimeOfDay.fromDateTime(last).format(ctx)}'),
              ],
              const SizedBox(height: 16),
              if (sync.state == SyncState.noPermission)
                FilledButton(onPressed: openAppSettings, child: const Text('Открыть разрешения'))
              else
                OutlinedButton(
                  onPressed: () {
                    sync.restart();
                    server.poke();
                  },
                  child: const Text('Переподключиться'),
                ),
            ]),
          ),
        );
      },
    ),
  );
}
