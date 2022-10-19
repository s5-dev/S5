import 'dart:io';
import 'package:tint/tint.dart';

import 'base.dart';

class ConsoleLogger extends Logger {
  @override
  void info(String s) {
    print(s);
  }

  @override
  void error(String s) {
    stderr.writeln(s.onRed().bold());
  }

  @override
  void verbose(String s) {
    stdout.writeln(s.grey());
  }

  @override
  void warn(String s) {
    stderr.writeln(s.yellow());
  }

  @override
  void catched(e, st) {
    warn(e.toString());
    verbose(st.toString());
  }
}
