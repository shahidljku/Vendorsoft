import 'dart:async';
import 'package:flutter/material.dart';
import '../services/cooldown_service.dart';

class CooldownFab extends StatefulWidget {
  final String label;
  final IconData iconData;
  final Color baseColor;
  final VoidCallback onCooldownAction;
  final VoidCallback onNormalAction;

  const CooldownFab({
    super.key,
    required this.label,
    required this.iconData,
    required this.baseColor,
    required this.onCooldownAction,
    required this.onNormalAction,
  });

  @override
  State<CooldownFab> createState() => _CooldownFabState();
}

class _CooldownFabState extends State<CooldownFab> {
  Timer? _timer;
  bool _isCooldown = false;
  Duration _remaining = Duration.zero;

  @override
  void initState() {
    super.initState();
    _check();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _check());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _check() async {
    bool active = await CooldownService().isCooldownActive();
    Duration rem = await CooldownService().getRemainingCooldown();
    if (mounted && (_isCooldown != active || _remaining.inSeconds != rem.inSeconds)) {
      setState(() {
        _isCooldown = active;
        _remaining = rem;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    String currentLabel = _isCooldown ? 'Cooldown (${CooldownService.formatDuration(_remaining)})' : widget.label;
    IconData currentIcon = _isCooldown ? Icons.timer : widget.iconData;
    Color currentColor = _isCooldown ? Colors.orange : widget.baseColor;
    VoidCallback currentAction = _isCooldown ? widget.onCooldownAction : widget.onNormalAction;

    return FloatingActionButton.extended(
      onPressed: currentAction,
      backgroundColor: currentColor,
      foregroundColor: Colors.black,
      icon: Icon(currentIcon),
      label: Text(currentLabel),
    );
  }
}
