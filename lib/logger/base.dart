abstract class Logger {
  void info(String s);
  void verbose(String s);
  void warn(String s);
  void error(String s);
  void catched(dynamic e, dynamic st);
}
