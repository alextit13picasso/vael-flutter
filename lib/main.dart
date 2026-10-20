import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vael/screens/catalog_screen.dart';
import 'package:vael/services/entitlement_service.dart';

void main() async {
  // Гарантируем инициализацию сервисов Flutter перед блокировкой ориентации
  WidgetsFlutterBinding.ensureInitialized();
  
  // Жестко фиксируем приложение в портретном режиме (9:16)
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);

  // Ставим подписку на поток покупок стора до первого кадра,
  // иначе можно потерять события, пришедшие на старте приложения.
  await EntitlementService.instance.initialize();

  runApp(const VaelApp());
}

class VaelApp extends StatelessWidget {
  const VaelApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Vael',
      debugShowCheckedModeBanner: false, // Убираем назойливую плашку дебага
      theme: ThemeData(
        brightness: Brightness.dark,
        primarySwatch: Colors.grey,
      ),
      home: const CatalogScreen(),
    );
  }
}
