class Novel {
  final String id;
  final String title;
  final int durationMinutes;
  final String description;
  final bool isPremium;
  final String novelUrl;
  final String previewImageUrl;

  Novel({
    required this.id,
    required this.title,
    required this.durationMinutes,
    required this.description,
    required this.isPremium,
    required this.novelUrl,
    required this.previewImageUrl,
  });

  factory Novel.fromJson(Map<String, dynamic> json) {
    return Novel(
      id: json['id'] ?? '',
      title: json['title'] ?? '',
      durationMinutes: json['duration_minutes'] ?? 0,
      description: json['description'] ?? '',
      isPremium: json['is_premium'] ?? false,
      novelUrl: json['novel_url'] ?? '',
      previewImageUrl: json['preview_image_url'] ?? '',
    );
  }
}
