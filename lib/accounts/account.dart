class Account {
  final int id;
  final int createdAt;
  final String? email;
  final bool isRestricted;
  final int tier;

  Account({
    required this.id,
    required this.createdAt,
    required this.email,
    required this.isRestricted,
    required this.tier,
  });
  toJson() => {
        'id': id,
        'createdAt': createdAt,
        'email': email,
        'tier': tier,
        'isRestricted': isRestricted,
      };
}
