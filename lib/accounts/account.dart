class Account {
  final int id;
  final int createdAt;
  final String? email;
  final bool isRestricted;
  int get tier => 1;

  Account({
    required this.id,
    required this.createdAt,
    required this.email,
    required this.isRestricted,
  });
  toJson() => {
        'id': id,
        'createdAt': createdAt,
        'email': email,
        'tier': tier,
        'isRestricted': isRestricted,
      };
}
