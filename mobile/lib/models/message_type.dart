enum MessageType {
  text,
  image,
  audio,
  video,
  file;

  static MessageType fromString(String s) =>
      MessageType.values.firstWhere((e) => e.name == s, orElse: () => MessageType.text);
}
