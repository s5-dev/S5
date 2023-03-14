int calculateExpiry(Duration duration) {
  return (DateTime.now().add(duration).millisecondsSinceEpoch / 1000).round();
}
