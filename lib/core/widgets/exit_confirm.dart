import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Whether Back on the root screen should ask before leaving the app.
/// Android only: the web's Back is browser history, and iOS has no Back.
bool get exitConfirmApplies =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

bool _dialogOpen = false;

/// Asks "Exit `appName`?" and closes the app if the user confirms.
Future<void> confirmExitApp(BuildContext context, String appName) async {
  if (_dialogOpen) return;
  _dialogOpen = true;
  try {
    final exit = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Exit $appName?'),
        content: const Text('Are you sure you want to exit?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Exit'),
          ),
        ],
      ),
    );
    if (exit ?? false) await SystemNavigator.pop();
  } finally {
    _dialogOpen = false;
  }
}

/// Wraps the app's root screen so system Back asks before exiting.
class ExitConfirmScope extends StatelessWidget {
  const ExitConfirmScope({
    super.key,
    required this.appName,
    required this.child,
  });

  final String appName;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!exitConfirmApplies) return child;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) confirmExitApp(context, appName);
      },
      child: child,
    );
  }
}
