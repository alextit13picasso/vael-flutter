import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart'; // Официальный плагин от Google

class ReaderScreen extends StatefulWidget {
  final String novelUrl;
  final String title;

  const ReaderScreen({
    Key? key,
    required this.novelUrl,
    required this.title,
  }) : super(key: key);

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  late final WebViewController _controller;

  @override
  void initState() {
    super.initState();
    // Включаем "липкий" полноэкранный режим Android
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    // Инициализируем контроллер WebView по канонам нового движка
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted) // Разрешаем JS для Monogatari
      ..setBackgroundColor(Colors.black) // Защита от белых вспышек при загрузке
      ..setNavigationDelegate(
        NavigationDelegate(
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
    // Возвращаем панели навигации Android в исходный вид при выходе в каталог
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, result) async {
          if (didPop) return;

          // Проверяем внутренний баланс переходов самого браузера
          if (await _controller.canGoBack()) {
            await _controller.goBack();
          } else {
            // Если вышли в корень новеллы — закрываем fullscreen-контейнер
            Navigator.of(context).pop();
          }
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
