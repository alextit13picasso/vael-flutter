import 'package:flutter/foundation.dart';

/// Статус доступа пользователя к новелле.
enum AccessStatus {
  /// Доступ разрешён: новелла бесплатная, куплена или есть активная подписка.
  granted,

  /// Нужна активная подписка Vael Club (открывает весь каталог).
  requiresSubscription,

  /// Нужно купить конкретную новеллу.
  requiresPurchase,
}

/// Покупка новеллы. Пока просто entity-заглушка под будущую библиотеку покупок.
class NovelPurchase {
  final String novelId;
  final DateTime purchasedAt;

  const NovelPurchase({
    required this.novelId,
    required this.purchasedAt,
  });
}

/// Подписка Vael Club. Пока просто entity-заглушка под будущую библиотеку подписок.
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

/// Сервис проверки прав доступа к платному контенту.
///
/// Сейчас это **заглушка**: реальные покупки и подписки ещё не подключены.
/// Когда будет выбрана библиотека (in_app_purchase / RevenueCat и т.п.),
/// достаточно будет заменить тела [purchaseNovel], [subscribeToClub] и
/// [fetchActiveSubscription] — остальной код приложения менять не придётся.
class EntitlementService {
  EntitlementService._();

  static final EntitlementService instance = EntitlementService._();

  /// Купленные новеллы (in-memory заглушка вместо локальной БД/сервера).
  final Set<String> _purchasedNovelIds = <String>{};

  /// Текущая подписка (если есть).
  VaelSubscription? _subscription;

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
    // TODO(subscriptions): подтянуть реальный статус из библиотеки подписок.
    final subscription = _subscription;
    if (subscription == null || !subscription.isActive) return null;
    return subscription;
  }

  /// Пока реальная оплата не подключена, стаб-покупка сразу выдаёт доступ —
  /// так можно проверять флоу «купил → чтение продолжается со 2-й главы».
  /// Поставьте `false`, чтобы увидеть ветку неудачной оплаты.
  static const bool stubPurchasesSucceed = true;

  /// Покупка конкретной новеллы.
  ///
  /// `true` — покупка прошла успешно и доступ выдан.
  Future<bool> purchaseNovel(String novelId) async {
    // TODO(purchases): здесь будет вызов библиотеки покупок.
    await Future<void>.delayed(const Duration(milliseconds: 600));
    if (!stubPurchasesSucceed) return false;

    _purchasedNovelIds.add(novelId);
    debugPrint('EntitlementService: СТАБ-покупка "$novelId" — доступ выдан');
    return true;
  }

  /// Оформление подписки Vael Club.
  ///
  /// `true` — подписка оформлена и доступ выдан.
  Future<bool> subscribeToClub() async {
    // TODO(subscriptions): здесь будет вызов библиотеки подписок.
    await Future<void>.delayed(const Duration(milliseconds: 600));
    if (!stubPurchasesSucceed) return false;

    final now = DateTime.now();
    _subscription = VaelSubscription(
      planId: 'stub_monthly',
      startedAt: now,
      expiresAt: now.add(const Duration(days: 30)),
    );
    debugPrint('EntitlementService: СТАБ-подписка оформлена — доступ выдан');
    return true;
  }

  // ---------------------------------------------------------------------------
  // Отладочные методы — позволяют проверить ветку "доступ есть" без оплаты.
  // ---------------------------------------------------------------------------

  /// Эмулирует успешную покупку новеллы.
  @visibleForTesting
  void debugGrantNovel(String novelId) {
    _purchasedNovelIds.add(novelId);
  }

  /// Эмулирует активную подписку.
  @visibleForTesting
  void debugGrantSubscription({Duration duration = const Duration(days: 30)}) {
    final now = DateTime.now();
    _subscription = VaelSubscription(
      planId: 'debug',
      startedAt: now,
      expiresAt: now.add(duration),
    );
  }

  /// Сбрасывает все эмуляции и отзывает доступ.
  @visibleForTesting
  void debugReset() {
    _purchasedNovelIds.clear();
    _subscription = null;
  }

  /// Купленные новеллы (только для отладки/тестов).
  @visibleForTesting
  Set<String> get debugPurchasedNovelIds => Set.unmodifiable(_purchasedNovelIds);
}
