import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:vael/models/novel.dart';

class ApiService {
  static const String _configUrl = 'https://alextit13picasso.github.io/vael-catalog/catalog.json';

  Future<List<Novel>> fetchCatalog() async {
    try {
      final response = await http.get(Uri.parse(_configUrl));

      if (response.statusCode == 200) {
        // Декодируем байты ответа в UTF-8 строку, затем в Map
        final Map<String, dynamic> data = json.decode(utf8.decode(response.bodyBytes));
        final List<dynamic> novelsJson = data['novels'] ?? [];
        
        // Превращаем массив JSON в список объектов Dart
        return novelsJson.map((json) => Novel.fromJson(json)).toList();
      } else {
        throw Exception('Ошибка сервера: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Не удалось загрузить каталог Vael: $e');
    }
  }
}
