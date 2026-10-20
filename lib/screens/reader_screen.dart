import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vael/services/entitlement_service.dart';
import 'package:vael/services/novel_bridge_script.dart';
import 'package:vael/widgets/paywall_sheet.dart';
import 'package:webview_flutter/webview_flutter.dart'; // Официальный плагин от Google

class ReaderScreen extends StatefulWidget {
  final String novelUrl;
  final String title;

  /// Идентификатор новеллы в каталоге (нужен для проверки покупок).
  final String novelId;

  /// Платная ли новелла. Для бесплатных проверка доступа не требуется.
  final bool isPremium;

  const ReaderScreen({
    Key? key,
    required this.novelUrl,
    required this.title,
    this.novelId = '',
    this.isPremium = false,
  }) : super(key: key);

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> with WidgetsBindingObserver {
  /// Номер главы, дочитывание которой ещё бесплатно.
  static const int _freeChapter = 1;

  late final WebViewController _controller;

  /// Первая глава уже дочитана — повторно paywall не показываем.
  bool _previewFinished = false;

  /// Защита от одновременного показа двух paywall-листов.
  bool _paywallVisible = false;

  /// Новелла стоит на паузе из-за paywall — тогда лайфсайкл её не возобновляет.
  bool _gateHold = false;

  /// Приложение ушло в фон — новелла приостановлена.
  bool _lifecyclePaused = false;

  /// Экран уже закрывается — дальше ничего не запускаем.
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Включаем "липкий" полноэкранный режим Android
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    // Инициализируем контроллер WebView по канонам нового движка
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted) // Разрешаем JS для Monogatari
      ..setBackgroundColor(Colors.black) // Защита от белых вспышек при загрузке
      ..addJavaScriptChannel(
        NovelBridgeScript.channelName,
        onMessageReceived: _onBridgeMessage,
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          // Внедряем мост как можно раньше: новелла вызывает
          // window.sendVaelGoal() из своего скрипта, и функция должна
          // существовать к этому моменту.
          onPageStarted: (url) async {
            await _installBridge();
          },
          // И ещё раз после загрузки — на случай, если JS-контекст
          // пересоздался на середине загрузки.
          onPageFinished: (url) async {
            await _installBridge();
          },
          onWebResourceError: (WebResourceError error) {
            debugPrint('Ошибка WebView: ${error.description}');
          },
        ),
      );

    // Включаем автостарт звуков без тапа (платформенная настройка Android)
    final platformController = _controller.platform;
    if (platformController is WebViewController) {
      // platformController.setMediaPlaybackRequiresUserGesture(false); TODO()
    }

    // Загружаем новеллу
    _controller.loadRequest(Uri.parse(widget.novelUrl));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);

    // Страховка: если экран закрылся не через _closeReader (например,
    // родительский маршрут убрали программно) — всё равно глушим новеллу.
    if (!_closed) {
      _closed = true;
      unawaited(_runBridgeScriptRaw(NovelBridgeScript.stop));
    }

    // Возвращаем панели навигации Android в исходный вид при выходе в каталог
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Лайфсайкл приложения: в фоне новелла не должна играть
  // ---------------------------------------------------------------------------

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        if (!_lifecyclePaused) return;
        _lifecyclePaused = false;
        // Если висит paywall — пусть остаётся на паузе,
        // снимет её код оплаты.
        if (_gateHold) return;
        unawaited(_releaseNovel());
        break;
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        if (_lifecyclePaused) return;
        _lifecyclePaused = true;
        unawaited(_stopNovel());
        break;
    }
  }

  // ---------------------------------------------------------------------------
  // Мост новелла <-> Flutter
  // ---------------------------------------------------------------------------

  /// Внедряет JS-мост в текущий документ.
  ///
  /// Вызов идемпотентный: сам скрипт защищён флагом `__vaelBridgeInstalled`,
  /// поэтому его можно звать и на `onPageStarted`, и на `onPageFinished`.
  Future<void> _installBridge() async {
    try {
      await _controller.runJavaScript(NovelBridgeScript.installer);
      // Сообщаем новелле, какую главу считаем бесплатной и включён ли гейт.
      await _controller.runJavaScript(
        NovelBridgeScript.gateConfig(
          enabled: widget.isPremium,
          freeChapter: _freeChapter,
        ),
      );
    } catch (e) {
      debugPrint('Не удалось внедрить мост новеллы: $e');
    }
  }

  void _onBridgeMessage(JavaScriptMessage message) {
    final Map<String, dynamic> payload;
    try {
      payload = jsonDecode(message.message) as Map<String, dynamic>;
    } catch (_) {
      debugPrint('VaelBridge: не удалось разобрать сообщение: ${message.message}');
      return;
    }

    switch (payload['type']) {
      case 'chapter_completed':
        _handleChapterCompleted(payload['chapter']);
        break;
      case 'novel_goal':
        // Новелла сама сообщила о достижении цели (конец главы):
        // sendVaelGoal('read_chapter_1').
        final goal = payload['goal']?.toString();
        debugPrint('VaelBridge: sendVaelGoal($goal)');
        _handleChapterCompleted(_chapterFromGoal(goal));
        break;
      case 'reading_held':
      case 'reading_resumed':
      case 'bridge_error':
        // Служебные сообщения моста — только для отладки.
        debugPrint('VaelBridge: ${payload['type']} $payload');
        break;
      default:
        debugPrint('VaelBridge: неизвестное сообщение ${payload['type']}');
    }
  }

  /// Достаёт номер главы из имени цели: `read_chapter_1` → 1.
  int? _chapterFromGoal(String? goal) {
    if (goal == null) return null;
    final match = RegExp(r'(\d+)').firstMatch(goal);
    if (match == null) return null;
    return int.tryParse(match.group(1)!);
  }

  /// Глава дочитана — проверяем, есть ли у пользователя доступ к продолжению.
  Future<void> _handleChapterCompleted(dynamic rawChapter) async {
    final chapter = rawChapter is int
        ? rawChapter
        : int.tryParse('$rawChapter') ?? _freeChapter;

    // Гейтим только первую (бесплатную) главу: в остальные пользователь
    // попадает уже с проверенным доступом.
    if (chapter > _freeChapter) return;
    if (_previewFinished) return;
    _previewFinished = true;

    final status = await EntitlementService.instance.checkNovelAccess(
      novelId: widget.novelId,
      isPremium: widget.isPremium,
    );

    // Доступ есть (бесплатная новелла, покупка или подписка) — читаем дальше.
    // Новелла на всякий случай уже поставлена на паузу в JS — снимаем её.
    if (status == AccessStatus.granted) {
      await _releaseNovel();
      return;
    }

    // Новелла ставится на паузу синхронно в JS (внутри sendVaelGoal),
    // здесь просто дублируем вызов — он идемпотентный.
    _gateHold = true;
    await _holdNovel();

    if (!mounted || _paywallVisible) return;
    _paywallVisible = true;

    final unlocked = await showPaywallSheet(
      context: context,
      novelTitle: widget.title,
      status: status,
      onPurchase: () => EntitlementService.instance.purchaseNovel(widget.novelId),
      onSubscribe: () => EntitlementService.instance.subscribeToClub(),
    );

    _paywallVisible = false;
    if (!mounted) return;

    if (unlocked) {
      _gateHold = false;
      // Продолжаем чтение ровно с того места, куда шёл движок,
      // то есть со следующей главы.
      await _releaseNovel();
      return;
    }

    // Не купил и не подписался — возвращаем в каталог.
    await _closeReader();
  }

  /// Выполняет JS-скрипт моста. После закрытия экрана — уже ничего не делаем.
  Future<void> _runBridgeScript(String script) async {
    if (_closed) return;
    await _runBridgeScriptRaw(script);
  }

  /// То же самое, но без проверки `_closed` — для финальной остановки.
  Future<void> _runBridgeScriptRaw(String script) async {
    try {
      await _controller.runJavaScript(script);
    } catch (e) {
      debugPrint('VaelBridge: не удалось выполнить JS: $e');
    }
  }

  /// Ставит новеллу на паузу: глушит звук, таймеры и переход в след. главу.
  Future<void> _holdNovel() => _runBridgeScript(NovelBridgeScript.hold);

  /// Жёсткая остановка — звук выключается сразу и насовсем.
  Future<void> _stopNovel() => _runBridgeScript(NovelBridgeScript.stop);

  /// Снимает паузу и выполняет отложенный переход в начало следующей главы.
  Future<void> _releaseNovel() async {
    // В фоне или при закрытии экрана новеллу не возобновляем:
    // пауза снимется сама, когда приложение вернётся на передний план.
    if (_closed || _lifecyclePaused) return;
    await _runBridgeScript(NovelBridgeScript.release);
  }

  /// Гасит новеллу и закрывает экран читалки.
  Future<void> _closeReader() async {
    if (_closed) return;
    _closed = true;

    // Успеваем остановить звук до того, как WebView будет уничтожен.
    await _runBridgeScriptRaw(NovelBridgeScript.stop);

    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, result) async {
          if (didPop) return;

          // Пока висит paywall, «Назад» и свайп игнорируем полностью.
          if (_paywallVisible) return;

          // Проверяем внутренний баланс переходов самого браузера
          if (await _controller.canGoBack()) {
            // Внутри новеллы — обычная навигация, звук не трогаем.
            await _controller.goBack();
            return;
          }

          // Если вышли в корень новеллы — глушим её и закрываем контейнер
          await _closeReader();
        },
        child: SafeArea(
          top: false,
          bottom: false,
          child: WebViewWidget(controller: _controller), // Нативный виджет отображения
        ),
      ),
    );
  }
}
