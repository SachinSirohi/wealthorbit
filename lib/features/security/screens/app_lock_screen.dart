import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:local_auth/local_auth.dart';
import '../../../core/theme/wo_design.dart';

/// Full-screen biometric/device-credential lock shown before the app content
/// when app-lock is enabled. Fails open (unlocks) when the device cannot
/// authenticate, so the user is never bricked out of their own data.
class AppLockScreen extends StatefulWidget {
  final VoidCallback onUnlocked;
  const AppLockScreen({super.key, required this.onUnlocked});

  @override
  State<AppLockScreen> createState() => _AppLockScreenState();
}

class _AppLockScreenState extends State<AppLockScreen> {
  final _auth = LocalAuthentication();
  bool _authenticating = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _authenticate());
  }

  Future<void> _authenticate() async {
    if (_authenticating) return;
    setState(() {
      _authenticating = true;
      _error = null;
    });
    try {
      final supported = await _auth.isDeviceSupported();
      if (!supported) {
        widget.onUnlocked(); // fail open
        return;
      }
      final ok = await _auth.authenticate(
        localizedReason: 'Unlock WealthOrbit',
        options: const AuthenticationOptions(stickyAuth: true, biometricOnly: false),
      );
      if (ok) {
        widget.onUnlocked();
      } else if (mounted) {
        setState(() => _error = 'Authentication failed. Try again.');
      }
    } catch (e) {
      // If the platform throws (e.g. no enrolled credentials), fail open.
      widget.onUnlocked();
    } finally {
      if (mounted) setState(() => _authenticating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: WoColors.bg,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 96,
              height: 96,
              decoration: woCard(radius: 26, goldGlow: true),
              child: Icon(CupertinoIcons.lock_shield_fill, color: WoColors.gold, size: 42),
            ),
            const SizedBox(height: 28),
            Text('WealthOrbit', style: WoText.display()),
            const SizedBox(height: 8),
            Text('Locked for your privacy', style: WoText.body()),
            const SizedBox(height: 32),
            if (_error != null) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 40),
                child: WoNotice(_error!, color: WoColors.red, icon: Icons.error_outline),
              ),
              const SizedBox(height: 16),
            ],
            ElevatedButton.icon(
              onPressed: _authenticating ? null : _authenticate,
              icon: const Icon(CupertinoIcons.lock_open_fill, size: 18),
              label: const Text('Unlock'),
              style: WoButtons.primary,
            ),
          ],
        ),
      ),
    );
  }
}
