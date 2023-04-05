class User {
  final int id;
  final int createdAt;
  final String? email;
  int get tier => 1;

  User({
    required this.id,
    required this.createdAt,
    required this.email,
  });
  toJson() => {
        'id': id,
        'createdAt': createdAt,
        'email': email,
        'tier': tier,
      };
}
