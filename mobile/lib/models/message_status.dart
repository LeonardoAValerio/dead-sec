enum MessageStatus {
  pending,
  sent,
  delivered,
  read;

  static MessageStatus fromString(String s) =>
      MessageStatus.values.firstWhere((e) => e.name == s, orElse: () => MessageStatus.pending);
}
