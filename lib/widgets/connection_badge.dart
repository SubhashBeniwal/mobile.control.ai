import 'package:flutter/material.dart';

import '../services/relay_client.dart';

/// Small pill showing the relay connection state.
class ConnectionBadge extends StatelessWidget {
  const ConnectionBadge({super.key, required this.state});

  final RelayConnectionState state;

  @override
  Widget build(BuildContext context) {
    final (color, label, icon) = switch (state) {
      RelayConnectionState.connected => (Colors.green, 'Connected', Icons.check_circle),
      RelayConnectionState.connecting => (Colors.orange, 'Connecting…', Icons.sync),
      RelayConnectionState.disconnected => (Colors.red, 'Offline', Icons.cloud_off),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
