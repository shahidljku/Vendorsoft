import 'package:flutter/material.dart';
import '../services/security_service.dart';

/// PIN lock screen shown on app launch when PIN is enabled.
/// Supports setup mode (first time) and verify mode.
class PinLockScreen extends StatefulWidget {
  final SecurityService securityService;
  final bool isSetup;
  final VoidCallback onSuccess;

  const PinLockScreen({
    super.key,
    required this.securityService,
    required this.isSetup,
    required this.onSuccess,
  });

  @override
  State<PinLockScreen> createState() => _PinLockScreenState();
}

class _PinLockScreenState extends State<PinLockScreen> {
  String _pin = '';
  String _confirmPin = '';
  bool _isConfirmStep = false;
  String _error = '';
  bool _isProcessing = false;
  final int _pinLength = 4;

  void _onDigitPressed(String digit) {
    if (_isProcessing) return;
    setState(() {
      _error = '';

      if (widget.isSetup) {
        if (!_isConfirmStep) {
          if (_pin.length < _pinLength) {
            _pin += digit;
          }
          if (_pin.length == _pinLength) {
            _isConfirmStep = true;
          }
        } else {
          if (_confirmPin.length < _pinLength) {
            _confirmPin += digit;
          }
          if (_confirmPin.length == _pinLength) {
            _verifySetup();
          }
        }
      } else {
        if (_pin.length < _pinLength) {
          _pin += digit;
        }
        if (_pin.length == _pinLength) {
          _verifyPin();
        }
      }
    });
  }

  void _onBackspace() {
    if (_isProcessing) return;
    setState(() {
      _error = '';
      if (widget.isSetup && _isConfirmStep) {
        if (_confirmPin.isNotEmpty) {
          _confirmPin = _confirmPin.substring(0, _confirmPin.length - 1);
        }
      } else {
        if (_pin.isNotEmpty) {
          _pin = _pin.substring(0, _pin.length - 1);
        }
      }
    });
  }

  Future<void> _verifyPin() async {
    setState(() => _isProcessing = true);
    bool correct = await widget.securityService.verifyPin(_pin);
    if (!mounted) return;
    if (correct) {
      widget.onSuccess();
      // Keep _isProcessing true since we are succeeding and leaving the screen
    } else {
      setState(() {
        _isProcessing = false;
        _pin = '';
        _error = 'Incorrect PIN';
      });
    }
  }

  Future<void> _verifySetup() async {
    if (_pin == _confirmPin) {
      setState(() => _isProcessing = true);
      await widget.securityService.setPin(_pin);
      if (!mounted) return;
      widget.onSuccess();
    } else {
      setState(() {
        _confirmPin = '';
        _isConfirmStep = false;
        _pin = '';
        _error = 'PINs do not match. Try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    String currentPin = (widget.isSetup && _isConfirmStep)
        ? _confirmPin
        : _pin;

    String title = widget.isSetup
        ? (_isConfirmStep ? 'Confirm PIN' : 'Set PIN')
        : 'Enter PIN';

    return Scaffold(
      backgroundColor: const Color(0xFF0B1014),
      body: SafeArea(
          child: Column(
            children: [
              const Spacer(),
              
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24.0),
                child: Card(
                  elevation: 8,
                  color: const Color(0xFF161B22),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                  child: Padding(
                    padding: const EdgeInsets.all(32.0),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Lock icon
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: const Color(0xFF00E676).withValues(alpha: 0.1),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            widget.isSetup ? Icons.lock_open : Icons.lock,
                            size: 48,
                            color: const Color(0xFF00E676),
                          ),
                        ),

                        const SizedBox(height: 24),

                        Text(
                          title,
                          style: const TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),

                        const SizedBox(height: 8),

                        if (widget.isSetup && !_isConfirmStep)
                          const Text(
                            'Choose a 4-digit PIN',
                            style: TextStyle(color: Colors.white70),
                          ),

                        const SizedBox(height: 32),

            // PIN dots
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(_pinLength, (index) {
                bool filled = index < currentPin.length;
                return Container(
                  margin: const EdgeInsets.symmetric(horizontal: 8),
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: filled ? const Color(0xFF00E676) : Colors.transparent,
                    border: Border.all(
                      color: filled ? const Color(0xFF00E676) : Colors.white24,
                      width: 2,
                    ),
                  ),
                );
              }),
            ),

            const SizedBox(height: 24),

            // Error text
            if (_error.isNotEmpty)
              Text(
                _error,
                style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
              )
            else
              const SizedBox(height: 16),
              
                      ],
                    ),
                  ),
                ),
              ),
              
              const Spacer(),

              // Keypad
              _buildNumberPad(),

              const SizedBox(height: 32),
            ],
          ),
        ),
    );
  }

  Widget _buildNumberPad() {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: ['1', '2', '3'].map(_buildDigitButton).toList(),
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: ['4', '5', '6'].map(_buildDigitButton).toList(),
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: ['7', '8', '9'].map(_buildDigitButton).toList(),
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            // Empty space
            const SizedBox(width: 72, height: 72),
            _buildDigitButton('0'),
            // Backspace
            SizedBox(
              width: 72,
              height: 72,
              child: IconButton(
                icon: const Icon(Icons.backspace_outlined, color: Colors.white70),
                iconSize: 32,
                onPressed: _onBackspace,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildDigitButton(String digit) {
    return SizedBox(
      width: 72,
      height: 72,
      child: OutlinedButton(
        onPressed: () => _onDigitPressed(digit),
        style: OutlinedButton.styleFrom(
          shape: const CircleBorder(),
          padding: const EdgeInsets.all(16),
          side: const BorderSide(color: Colors.white12),
          foregroundColor: Colors.white,
        ),
        child: Text(
          digit,
          style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }
}
