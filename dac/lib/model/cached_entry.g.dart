// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'cached_entry.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class CachedEntryAdapter extends TypeAdapter<CachedEntry> {
  @override
  final int typeId = 5;

  @override
  CachedEntry read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return CachedEntry(
      revision: fields[1] as int,
      data: fields[2] as String,
      skylink: fields[3] as String?,
    );
  }

  @override
  void write(BinaryWriter writer, CachedEntry obj) {
    writer
      ..writeByte(3)
      ..writeByte(1)
      ..write(obj.revision)
      ..writeByte(2)
      ..write(obj.data)
      ..writeByte(3)
      ..write(obj.skylink);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CachedEntryAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
