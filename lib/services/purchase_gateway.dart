/// Товар, доступный в сторе приложения.
class StoreProduct {
  /// Идентификатор товара в Google Play Console / App Store Connect.
  final String id;

  /// Локализованное название из стора.
  final String title;

  /// Локализованное описание из стора.
  final String description;

  /// Готовая к показу цена с валютой (например, `$4.99`).
  final String price;

  const StoreProduct({
    required this.id,
    required this.title,
    required this.description,
    required this.price,
  });
}

/// Что произошло с покупкой.
enum PurchaseEventType {
  /// Покупка успешно завершена.
  purchased,

  /// Покупка восстановлена на новом устройстве.
  restored,

  /// Платёж в обработке (например, оплата наличными в Google Play).
  pending,

  /// Пользователь закрыл окно оплаты.
  canceled,

  /// Ошибка в сторе.
  failed,
}

/// Событие из стора.
class PurchaseEvent {
  final String productId;
  final PurchaseEventType type;
  final String? errorMessage;

  const PurchaseEvent(
    this.productId,
    this.type, {
    this.errorMessage,
  });

  @override
  String toString() => 'PurchaseEvent($productId, $type, $errorMessage)';
}

/// Абстракция над магазинами приложений.
///
/// Сейчас единственная реализация — [InAppPurchaseGateway] на официальном
/// плагине `in_app_purchase` (Google Play Billing / StoreKit).
/// Абстракция нужна, чтобы позже можно было подменить её на RevenueCat
/// или собственный бэкенд, не трогая остальной код приложения.
abstract class PurchaseGateway {
  /// Ставит подписку на поток покупок. Вызывать один раз на старте приложения.
  Future<void> initialize();

  /// Поток событий: покупки, восстановления, отмены и ошибки.
  Stream<PurchaseEvent> get events;

  /// Готов ли стор к работе (на эмуляторах без Play Store — `false`).
  Future<bool> isStoreAvailable();

  /// Возвращает товар с ценой или `null`, если товара нет в сторе.
  Future<StoreProduct?> loadProduct(String productId);

  /// Запускает покупку. `false` — запрос не удалось отправить.
  /// Результат придёт в [events].
  Future<bool> buy(String productId);

  /// Просит стор восстановить ранее купленное. Результат — в [events].
  Future<void> restorePurchases();

  /// Отписывается от потока покупок.
  Future<void> dispose();
}
