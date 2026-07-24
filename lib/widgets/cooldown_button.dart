import 'dart:async';
import 'package:flutter/material.dart';
import '../services/cooldown_service.dart';

class CooldownButton extends StatefulWidget {
  final String label;
  final IconData iconData;
  final Color baseColor;
  final VoidCallback onCooldownAction;
  final VoidCallback onNormalAction;

  const CooldownButton({
    super.key,
    required this.label,
    required this.iconData,
    required this.baseColor,
    required this.onCooldownAction,
    required this.onNormalAction,
  });

  @override
  State<CooldownButton> createState() => _CooldownButtonState();
}

class _CooldownButtonState extends State<CooldownButton> {
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

    return InkWell(
      onTap: currentAction,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: currentColor.withAlpha(38), // ~0.15 opacity
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: currentColor.withAlpha(76)), // ~0.3 opacity
        ),
        child: Column(
          children: [
            Icon(currentIcon, color: currentColor, size: 28),
            const SizedBox(height: 8),
            Text(currentLabel, style: TextStyle(color: currentColor, fontWeight: FontWeight.bold, fontSize: 13), textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
