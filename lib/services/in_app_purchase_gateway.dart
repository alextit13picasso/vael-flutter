import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:vael/services/purchase_gateway.dart';

/// Реализация [PurchaseGateway] на официальном плагине `in_app_purchase`:
/// Google Play Billing на Android и StoreKit на iOS.
///
/// Что нужно от стора (делается позже, когда приложение будет опубликовано):
/// * Google Play Console → Монетизация → Товары в приложении:
///     - подписка `vael_club_monthly` (auto-renewable);
///     - товар `novel_<id>` (разовая покупка) на каждую новеллу каталога.
/// * App Store Connect → In-App Purchases: те же идентификаторы.
/// * iOS: включить capability "In-App Purchases" в Xcode.
///
/// Пока товары не созданы, [loadProduct] возвращает `null` — это ожидаемо
/// и обрабатывается в `EntitlementService`.
class InAppPurchaseGateway implements PurchaseGateway {
  InAppPurchaseGateway({InAppPurchase? iap})
      : _iap = iap ?? InAppPurchase.instance;

  final InAppPurchase _iap;

  final StreamController<PurchaseEvent> _events =
      StreamController<PurchaseEvent>.broadcast();
  final Map<String, ProductDetails> _detailsCache = <String, ProductDetails>{};

  StreamSubscription<List<PurchaseDetails>>? _purchaseSubscription;
  bool _initialized = false;

  @override
  Stream<PurchaseEvent> get events => _events.stream;

  @override
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    // Подписка на поток обязательна до первого кадра: иначе можно потерять
    // покупки, которые стор присылает на старте приложения
    // (например, если прошлая сессия не успела вызвать completePurchase).
    _purchaseSubscription = _iap.purchaseStream.listen(
      _handlePurchases,
      onError: (Object error) {
        debugPrint('InAppPurchase: ошибка потока покупок: $error');
        _events.add(
          PurchaseEvent('', PurchaseEventType.failed, errorMessage: '$error'),
        );
      },
    );
  }

  @override
  Future<bool> isStoreAvailable() async {
    try {
      return await _iap.isAvailable();
    } catch (e) {
      debugPrint('InAppPurchase: стор недоступен: $e');
      return false;
    }
  }

  @override
  Future<StoreProduct?> loadProduct(String productId) async {
    final details = await _queryDetails(productId);
    if (details == null) return null;

    return StoreProduct(
      id: details.id,
      title: details.title,
      description: details.description,
      price: details.price,
    );
  }

  @override
  Future<bool> buy(String productId) async {
    final details = await _queryDetails(productId);
    if (details == null) return false;

    try {
      // И подписка, и разовая покупка новеллы в терминах плагина —
      // non-consumable: их нельзя «израсходовать» и они восстанавливаются.
      return await _iap.buyNonConsumable(
        purchaseParam: PurchaseParam(productDetails: details),
      );
    } catch (e) {
      debugPrint('InAppPurchase: не удалось начать покупку "$productId": $e');
      _events.add(
        PurchaseEvent(productId, PurchaseEventType.failed, errorMessage: '$e'),
      );
      return false;
    }
  }

  @override
  Future<void> restorePurchases() async {
    try {
      await _iap.restorePurchases();
    } catch (e) {
      debugPrint('InAppPurchase: не удалось восстановить покупки: $e');
    }
  }

  @override
  Future<void> dispose() async {
    await _purchaseSubscription?.cancel();
    _purchaseSubscription = null;
    await _events.close();
  }

  // ---------------------------------------------------------------------------

  Future<ProductDetails?> _queryDetails(String productId) async {
    final cached = _detailsCache[productId];
    if (cached != null) return cached;

    if (!await isStoreAvailable()) return null;

    try {
      final response = await _iap.queryProductDetails({productId});
      final details =
          response.productDetails.isEmpty ? null : response.productDetails.first;

      if (details == null) {
        debugPrint(
          'InAppPurchase: товар "$productId" не найден в сторе '
          '(notFound: ${response.notFoundIDs})',
        );
        return null;
      }

      _detailsCache[productId] = details;
      return details;
    } catch (e) {
      debugPrint('InAppPurchase: не удалось получить товар "$productId": $e');
      return null;
    }
  }

  Future<void> _handlePurchases(List<PurchaseDetails> purchases) async {
    for (final purchase in purchases) {
      final type = _eventTypeFor(purchase.status);
      if (type != null) {
        _events.add(
          PurchaseEvent(
            purchase.productID,
            type,
            errorMessage: purchase.error?.message,
          ),
        );
      }

      // Завершать надо purchased/restored (и error/canceled, если стор их
      // прислал с этим флагом), иначе iOS будет присылать транзакцию снова.
      if (purchase.pendingCompletePurchase) {
        try {
          await _iap.completePurchase(purchase);
        } catch (e) {
          debugPrint(
            'InAppPurchase: не удалось завершить покупку '
            '"${purchase.productID}": $e',
          );
        }
      }
    }
  }

  static PurchaseEventType? _eventTypeFor(PurchaseStatus status) {
    switch (status) {
      case PurchaseStatus.purchased:
        return PurchaseEventType.purchased;
      case PurchaseStatus.restored:
        return PurchaseEventType.restored;
      case PurchaseStatus.pending:
        return PurchaseEventType.pending;
      case PurchaseStatus.canceled:
        return PurchaseEventType.canceled;
      case PurchaseStatus.error:
        return PurchaseEventType.failed;
    }
  }
}
