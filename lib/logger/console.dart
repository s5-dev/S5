import 'dart:io';
import 'package:tint/tint.dart';

import 'base.dart';

class ConsoleLogger extends Logger {
  final String prefix;
  final bool format;

  ConsoleLogger({this.prefix = '', this.format = true});

  @override
  void info(String s) {
    print(prefix + s);
  }

  @override
  void error(String s) {
    stderr.writeln(prefix + s.onRed().bold());
  }

  @override
  void verbose(String s) {
    if (format) {
      stdout.writeln(prefix + s.grey());
    } else {
      stdout.writeln(prefix + s);
    }
  }

  @override
  void warn(String s) {
    stderr.writeln(prefix + s.yellow());
  }

  @override
  void catched(e, st) {
    warn(prefix + e.toString());
    verbose(prefix + st.toString());
  }
}
