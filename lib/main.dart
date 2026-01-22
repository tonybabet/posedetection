import 'package:flutter/material.dart';
import 'pages/pose_camera_page.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(home: PoseCameraPage()));
}
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: PoseCameraPage(),
    );
  }
}
