import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vael/services/in_app_purchase_gateway.dart';
import 'package:vael/services/purchase_gateway.dart';

/// Статус доступа пользователя к новелле.
enum AccessStatus {
  /// Доступ разрешён: новелла бесплатная, куплена или есть активная подписка.
  granted,

  /// Нужна активная подписка Vael Club (открывает весь каталог).
  requiresSubscription,

  /// Нужно купить конкретную новеллу.
  requiresPurchase,
}

/// Покупка новеллы.
class NovelPurchase {
  final String novelId;
  final DateTime purchasedAt;

  const NovelPurchase({
    required this.novelId,
    required this.purchasedAt,
  });
}

/// Подписка Vael Club.
class VaelSubscription {
  final String planId;
  final DateTime startedAt;
  final DateTime? expiresAt;

  const VaelSubscription({
    required this.planId,
    required this.startedAt,
    this.expiresAt,
  });

  /// `true`, если подписка бессрочная или срок её действия ещё не истёк.
  bool get isActive {
    final expiry = expiresAt;
    return expiry == null || expiry.isAfter(DateTime.now());
  }
}

/// Права доступа пользователя к платному контенту.
///
/// Работает поверх [PurchaseGateway] (сейчас — официальный `in_app_purchase`,
/// то есть Google Play Billing и StoreKit). Всё, что делает сервис:
/// * проверяет доступ к новелле;
/// * запускает покупку/подписку и раздаёт права по событиям стора;
/// * кэширует права локально, чтобы paywall не появлялся повторно офлайн.
///
/// Что осталось на потом (когда приложение попадёт в сторы):
/// * проверка чеков на бэкенде (Play Developer API / App Store Server API);
/// * реальная дата окончания подписки — сейчас ставится «+31 день».
class EntitlementService {
  EntitlementService._();

  static final EntitlementService instance = EntitlementService._();

  /// ID подписки в Google Play Console / App Store Connect.
  static const String subscriptionProductId = 'vael_club_monthly';

  /// ID разовой покупки новеллы: `novel_<id из каталога>`.
  static String novelProductIdFor(String novelId) => 'novel_$novelId';

  /// Пока стор не настроен (приложение не опубликовано, товары не созданы),
  /// в debug-сборке эмулируем успешную оплату — иначе флоу не проверить.
  /// В release-сборке заглушка выключена и покупка честно падает.
  static const bool allowStubWhenStoreUnavailable = kDebugMode;

  static const String _novelsKey = 'vael.entitlements.novels';
  static const String _subscriptionKey = 'vael.entitlements.subscription';

  PurchaseGateway _gateway = InAppPurchaseGateway();
  StreamSubscription<PurchaseEvent>? _eventsSubscription;
  final Map<String, Completer<bool>> _pendingPurchases = {};

  final Set<String> _purchasedNovelIds = <String>{};
  VaelSubscription? _subscription;
  bool _initialized = false;

  /// Вызывается один раз на старте приложения — до `runApp`.
  ///
  /// Подписка на поток покупок ставится здесь, чтобы не потерять события,
  /// которые стор присылает сразу после запуска.
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    await _loadPersisted();
    await _gateway.initialize();
    _eventsSubscription = _gateway.events.listen(_onPurchaseEvent);
  }

  /// Главная точка входа: можно ли читать новеллу дальше.
  ///
  /// Вызывается, например, после бесплатной первой главы.
  Future<AccessStatus> checkNovelAccess({
    required String novelId,
    required bool isPremium,
  }) async {
    // Бесплатная новелла — доступна всегда.
    if (!isPremium) return AccessStatus.granted;

    // Новелла уже куплена.
    if (_purchasedNovelIds.contains(novelId)) return AccessStatus.granted;

    // Есть активная подписка — она открывает весь каталог.
    final subscription = await fetchActiveSubscription();
    if (subscription != null) return AccessStatus.granted;

    // По умолчанию предлагаем подписку (она выгоднее и открывает всё).
    return AccessStatus.requiresSubscription;
  }

  /// Возвращает активную подписку или `null`, если её нет.
  Future<VaelSubscription?> fetchActiveSubscription() async {
    final subscription = _subscription;
    if (subscription == null || !subscription.isActive) return null;
    return subscription;
  }

  /// Покупка конкретной новеллы. `true` — доступ выдан.
  Future<bool> purchaseNovel(String novelId) async {
    if (novelId.isEmpty) return false;
    if (_purchasedNovelIds.contains(novelId)) return true;
    return _purchaseProduct(novelProductIdFor(novelId));
  }

  /// Оформление подписки Vael Club. `true` — доступ выдан.
  Future<bool> subscribeToClub() async {
    if (_subscription?.isActive == true) return true;
    return _purchaseProduct(subscriptionProductId);
  }

  /// Восстановление покупок (кнопка "Restore purchases").
  /// Результат прилетит через поток событий стора.
  Future<void> restorePurchases() => _gateway.restorePurchases();

  /// Доступные товары — для показа реальных цен на paywall.
  Future<StoreProduct?> loadSubscriptionProduct() =>
      _gateway.loadProduct(subscriptionProductId);

  Future<StoreProduct?> loadNovelProduct(String novelId) =>
      _gateway.loadProduct(novelProductIdFor(novelId));

  // ---------------------------------------------------------------------------
  // Покупка
  // ---------------------------------------------------------------------------

  Future<bool> _purchaseProduct(String productId) async {
    final product = await _gateway.loadProduct(productId);

    // Товара нет: приложение не опубликовано или товар не создан в консоли.
    if (product == null) {
      if (allowStubWhenStoreUnavailable) {
        debugPrint(
          'EntitlementService: СТАБ-покупка "$productId" — товар не найден '
          'в сторе, debug-сборка выдаёт доступ. '
          'Создайте товар в Google Play Console / App Store Connect.',
        );
        await Future<void>.delayed(const Duration(milliseconds: 600));
        await _grant(productId);
        return true;
      }

      debugPrint('EntitlementService: товар "$productId" недоступен в сторе');
      return false;
    }

    final completer = Completer<bool>();
    _pendingPurchases[productId] = completer;

    final started = await _gateway.buy(productId);
    if (!started) {
      _pendingPurchases.remove(productId);
      return false;
    }

    try {
      return await completer.future.timeout(
        const Duration(minutes: 5),
        onTimeout: () {
          debugPrint('EntitlementService: покупка "$productId" не завершилась');
          return false;
        },
      );
    } finally {
      _pendingPurchases.remove(productId);
    }
  }

  Future<void> _onPurchaseEvent(PurchaseEvent event) async {
    debugPrint('EntitlementService: стор → $event');

    switch (event.type) {
      case PurchaseEventType.purchased:
      case PurchaseEventType.restored:
        await _grant(event.productId);
        _resolvePending(event.productId, granted: true);
        break;
      case PurchaseEventType.canceled:
      case PurchaseEventType.failed:
        _resolvePending(event.productId, granted: false);
        break;
      case PurchaseEventType.pending:
        break;
    }
  }

  void _resolvePending(String productId, {required bool granted}) {
    final completer = _pendingPurchases[productId];
    if (completer == null || completer.isCompleted) return;
    completer.complete(granted);
  }

  /// Выдаёт права по ID товара и сохраняет их локально.
  Future<void> _grant(String productId) async {
    if (productId.isEmpty) return;

    if (productId == subscriptionProductId) {
      if (_subscription?.isActive == true) return;
      final now = DateTime.now();
      _subscription = VaelSubscription(
        planId: productId,
        startedAt: now,
        // TODO(purchases): реальную дату продления даёт проверка чека
        // (Play Developer API / App Store Server API). Клиент её не знает.
        expiresAt: now.add(const Duration(days: 31)),
      );
      await _persist();
      return;
    }

    final novelId = _novelIdFromProductId(productId);
    if (novelId == null) return;
    if (!_purchasedNovelIds.add(novelId)) return;

    await _persist();
  }

  /// `novel_brought_coffee_01` → `brought_coffee_01`.
  static String? _novelIdFromProductId(String productId) {
    const prefix = 'novel_';
    if (!productId.startsWith(prefix)) return null;
    final novelId = productId.substring(prefix.length);
    return novelId.isEmpty ? null : novelId;
  }

  // ---------------------------------------------------------------------------
  // Локальный кэш прав
  // ---------------------------------------------------------------------------

  Future<void> _loadPersisted() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      _purchasedNovelIds.addAll(prefs.getStringList(_novelsKey) ?? const []);

      final rawSubscription = prefs.getString(_subscriptionKey);
      if (rawSubscription != null) {
        final json = jsonDecode(rawSubscription) as Map<String, dynamic>;
        _subscription = VaelSubscription(
          planId: json['planId'] as String? ?? subscriptionProductId,
          startedAt: DateTime.tryParse(json['startedAt'] as String? ?? '') ??
              DateTime.now(),
          expiresAt: DateTime.tryParse(json['expiresAt'] as String? ?? ''),
        );
      }
    } catch (e) {
      debugPrint('EntitlementService: не удалось прочитать покупки: $e');
    }
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_novelsKey, _purchasedNovelIds.toList());

      final subscription = _subscription;
      if (subscription == null) {
        await prefs.remove(_subscriptionKey);
      } else {
        await prefs.setString(
          _subscriptionKey,
          jsonEncode({
            'planId': subscription.planId,
            'startedAt': subscription.startedAt.toIso8601String(),
            'expiresAt': subscription.expiresAt?.toIso8601String(),
          }),
        );
      }
    } catch (e) {
      debugPrint('EntitlementService: не удалось сохранить покупки: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Отладка и тесты
  // ---------------------------------------------------------------------------

  /// Подменяет шлюз (для тестов).
  @visibleForTesting
  void useGateway(PurchaseGateway gateway) {
    _eventsSubscription?.cancel();
    _gateway = gateway;
    _initialized = false;
  }

  /// Эмулирует успешную покупку новеллы.
  @visibleForTesting
  Future<void> debugGrantNovel(String novelId) =>
      _grant(novelProductIdFor(novelId));

  /// Эмулирует активную подписку.
  @visibleForTesting
  Future<void> debugGrantSubscription({
    Duration duration = const Duration(days: 31),
  }) async {
    final now = DateTime.now();
    _subscription = VaelSubscription(
      planId: subscriptionProductId,
      startedAt: now,
      expiresAt: now.add(duration),
    );
    await _persist();
  }

  /// Сбрасывает все покупки и подписку.
  @visibleForTesting
  Future<void> debugReset() async {
    _purchasedNovelIds.clear();
    _subscription = null;
    await _persist();
  }

  /// Купленные новеллы (только для отладки/тестов).
  @visibleForTesting
  Set<String> get debugPurchasedNovelIds => Set.unmodifiable(_purchasedNovelIds);
}
