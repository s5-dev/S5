import 'dart:math';

// TODO nodes with a score below 0.2 should be disconnected immediately and responses dropped

double calculateScore(int goodResponses, int badResponses) {
  final totalVotes = goodResponses + badResponses;
  if (totalVotes == 0) return 0.5;

  final average = goodResponses / totalVotes;
  final score = average - (average - 0.5) * pow(2, -log(totalVotes + 1));

  return score;
}
