import 'package:flutter/material.dart';

final ThemeData cypherpunkNinjaTheme = ThemeData(
  brightness: Brightness.dark,
  scaffoldBackgroundColor: Colors.black,
  primaryColor: Colors.greenAccent,
  colorScheme: const ColorScheme.dark(
    primary: Colors.greenAccent,
    secondary: Colors.tealAccent,
    surface: Color(0xFF111111),
    error: Colors.redAccent,
  ),
  drawerTheme: const DrawerThemeData(
    backgroundColor: Color(0xFF111111), // <--- Sidebar color
    surfaceTintColor: Colors.transparent,
  ),
  appBarTheme: const AppBarTheme(
    backgroundColor: Colors.black,
    elevation: 0,
    iconTheme: IconThemeData(color: Colors.greenAccent),
    titleTextStyle: TextStyle(
      color: Colors.greenAccent,
      fontSize: 20,
      fontWeight: FontWeight.bold,
    ),
  ),
  bottomNavigationBarTheme: const BottomNavigationBarThemeData(
    backgroundColor: Colors.black,
    selectedItemColor: Colors.greenAccent,
    unselectedItemColor: Colors.grey,
  ),
  textTheme: const TextTheme(
    bodyLarge: TextStyle(color: Colors.white),
    bodyMedium: TextStyle(color: Colors.white70),
    titleLarge: TextStyle(
      color: Colors.greenAccent,
      fontWeight: FontWeight.bold,
    ),
  ),
  buttonTheme: const ButtonThemeData(
    buttonColor: Colors.greenAccent,
    textTheme: ButtonTextTheme.primary,
  ),
  floatingActionButtonTheme: const FloatingActionButtonThemeData(
    backgroundColor: Colors.greenAccent,
    foregroundColor: Colors.black,
  ),
  iconTheme: const IconThemeData(color: Colors.greenAccent),
  bottomSheetTheme: const BottomSheetThemeData(
    backgroundColor: Color(0xFF111111),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
  ),
);

Future<T?> showCarbineModalBottomSheet<T>({
  required BuildContext context,
  required Widget child,
  double? heightFactor,
}) {
  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: Theme.of(context).bottomSheetTheme.backgroundColor,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (context) {
      return SafeArea(
        child: FractionallySizedBox(
          heightFactor: heightFactor ?? 0.8,
          child: Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(context).viewInsets.bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Optional grab handle
                Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(
                    color: Colors.grey[700],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                // Scrollable content
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: child,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
