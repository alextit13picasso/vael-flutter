import 'package:flutter/material.dart';
import 'package:vael/services/entitlement_service.dart';

/// Показывает paywall: предложение оформить подписку или купить новеллу.
///
/// Возвращает `true`, если доступ удалось получить (покупка/подписка прошла).
/// Возвращает `false`, если пользователь закрыл лист кнопкой "Back to catalog".
///
/// Лист намеренно нельзя закрыть свайпом, тапом по фону или системной
/// кнопкой "Назад" — выход только осознанной кнопкой.
Future<bool> showPaywallSheet({
  required BuildContext context,
  required String novelTitle,
  AccessStatus status = AccessStatus.requiresSubscription,
  required Future<bool> Function() onPurchase,
  required Future<bool> Function() onSubscribe,
}) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    isDismissible: false,
    enableDrag: false,
    useSafeArea: true,
    backgroundColor: const Color(0xFF1A1A1A),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (sheetContext) => _PaywallSheet(
      novelTitle: novelTitle,
      status: status,
      onPurchase: onPurchase,
      onSubscribe: onSubscribe,
    ),
  );
  return result ?? false;
}

class _PaywallSheet extends StatefulWidget {
  final String novelTitle;
  final AccessStatus status;
  final Future<bool> Function() onPurchase;
  final Future<bool> Function() onSubscribe;

  const _PaywallSheet({
    required this.novelTitle,
    required this.status,
    required this.onPurchase,
    required this.onSubscribe,
  });

  @override
  State<_PaywallSheet> createState() => _PaywallSheetState();
}

class _PaywallSheetState extends State<_PaywallSheet> {
  bool _busy = false;

  Future<void> _run(Future<bool> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);

    final unlocked = await action();

    if (!mounted) return;
    setState(() => _busy = false);

    if (unlocked) {
      Navigator.of(context).pop(true);
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Payment failed. Please try again later.'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isSubscription = widget.status == AccessStatus.requiresSubscription;

    // canPop: false — блокируем и системную кнопку "Назад",
    // и свайп-назад (включая predictive back).
    return PopScope(
      canPop: false,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.lock_outline, color: Colors.amber, size: 32),
              const SizedBox(height: 12),
              const Text(
                'You have finished Chapter 1',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                isSubscription
                    ? 'Continue reading “${widget.novelTitle}” and every other '
                        'Vael story with a Vael Club subscription.'
                    : 'To continue reading “${widget.novelTitle}”, buy this '
                        'novel or start a Vael Club subscription.',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 14,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.amber,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                onPressed: _busy ? null : () => _run(widget.onSubscribe),
                child: _busy
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.black,
                        ),
                      )
                    : const Text(
                        'Start Vael Club subscription',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
              ),
              const SizedBox(height: 10),
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Colors.white24),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                onPressed: _busy ? null : () => _run(widget.onPurchase),
                child: Text('Buy “${widget.novelTitle}”'),
              ),
              const SizedBox(height: 4),
              TextButton(
                style: TextButton.styleFrom(foregroundColor: Colors.white54),
                onPressed:
                    _busy ? null : () => Navigator.of(context).pop(false),
                child: const Text('Back to catalog'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
