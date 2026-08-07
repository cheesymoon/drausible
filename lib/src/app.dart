import 'package:flutter/material.dart';

import 'ui/screens/server_list_screen.dart';

const Color _seedColor = Color(0xFF443CC4);

class DrausibleApp extends StatelessWidget {
  const DrausibleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Drausible',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: _seedColor),
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: _seedColor,
          brightness: Brightness.dark,
        ),
      ),
      themeMode: ThemeMode.system,
      home: const ServerListScreen(),
    );
  }
}
