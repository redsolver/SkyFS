import 'package:hive/hive.dart';

part 'cached_entry.g.dart';

@HiveType(typeId: 5)
class CachedEntry {
  @HiveField(1)
  final int revision;
  @HiveField(2)
  final String data;

  @HiveField(3)
  final String? skylink;

  CachedEntry({
    required this.revision,
    required this.data,
    required this.skylink,
  });

  Map<String, dynamic> toJson() => {'r': revision, 'd': data, 's': skylink};
}
