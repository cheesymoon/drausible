// Locally-unique id for servers and sites. No uuid package needed.
String generateId() => DateTime.now().microsecondsSinceEpoch.toRadixString(36);
