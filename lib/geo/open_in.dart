// «Открыть в навигаторе»: Google Maps, Apple Карты (iPhone), Organic Maps, OsmAnd или выбор системы.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

Future<void> showOpenIn(BuildContext context, double lat, double lng, String label) async {
  final messenger = ScaffoldMessenger.of(context);
  final name = Uri.encodeComponent(label);
  final ios = defaultTargetPlatform == TargetPlatform.iOS;
  final options = <(IconData, String, Uri)>[
    (Icons.map_outlined, 'Google Maps', Uri.parse('https://www.google.com/maps/dir/?api=1&destination=$lat,$lng')),
    if (ios) (Icons.map, 'Apple Карты', Uri.parse('https://maps.apple.com/?daddr=$lat,$lng&q=$name')),
    (Icons.explore_outlined, 'Organic Maps', Uri.parse('om://map?v=1&ll=$lat,$lng&n=$name')),
    (Icons.terrain_outlined, 'OsmAnd', Uri.parse('osmandmaps://?lat=$lat&lon=$lng&z=16&title=$name')),
    if (!ios) (Icons.apps, 'Другое приложение', Uri.parse('geo:$lat,$lng?q=$lat,$lng($name)')),
  ];
  await showModalBottomSheet(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(title: Text('Открыть «$label»', style: const TextStyle(fontWeight: FontWeight.w600))),
        for (final (icon, title, uri) in options)
          ListTile(
            leading: Icon(icon),
            title: Text(title),
            onTap: () async {
              Navigator.pop(ctx);
              var ok = false;
              try {
                ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
              } catch (_) {}
              if (!ok) messenger.showSnackBar(SnackBar(content: Text('$title не установлено на телефоне')));
            },
          ),
      ]),
    ),
  );
}
