import 'package:flutter/material.dart';

const Color vibrantBlue = Color(0xFF42CFFF);

final ThemeData cypherpunkNinjaTheme = ThemeData(
  brightness: Brightness.dark,
  scaffoldBackgroundColor: Colors.black,
  primaryColor: vibrantBlue,
  colorScheme: const ColorScheme.dark(
    primary: vibrantBlue,
    secondary: Color(0xFF3399FF),
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
    iconTheme: IconThemeData(color: vibrantBlue),
    titleTextStyle: TextStyle(
      color: vibrantBlue,
      fontSize: 20,
      fontWeight: FontWeight.bold,
    ),
  ),
  bottomNavigationBarTheme: const BottomNavigationBarThemeData(
    backgroundColor: Colors.black,
    selectedItemColor: vibrantBlue,
    unselectedItemColor: Colors.grey,
  ),
  textTheme: const TextTheme(
    bodyLarge: TextStyle(color: Colors.white),
    bodyMedium: TextStyle(color: Colors.white70),
    titleLarge: TextStyle(color: vibrantBlue, fontWeight: FontWeight.bold),
  ),
  buttonTheme: const ButtonThemeData(
    buttonColor: vibrantBlue,
    textTheme: ButtonTextTheme.primary,
  ),
  floatingActionButtonTheme: const FloatingActionButtonThemeData(
    backgroundColor: vibrantBlue,
    foregroundColor: Colors.black,
  ),
  iconTheme: const IconThemeData(color: vibrantBlue),
  bottomSheetTheme: const BottomSheetThemeData(
    backgroundColor: Color(0xFF111111),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
  ),
);

Future<T?> showAppModalBottomSheet<T>({
  required BuildContext context,
  required Future<Widget> Function() childBuilder,
  double? heightFactor,
}) {
  final childFuture = childBuilder();
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
                // Async content
                Expanded(
                  child: FutureBuilder<Widget>(
                    future: childFuture,
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.waiting) {
                        return const Center(
                          child: Padding(
                            padding: EdgeInsets.all(24.0),
                            child: CircularProgressIndicator(),
                          ),
                        );
                      } else if (snapshot.hasError) {
                        return Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24.0),
                            child: Text(
                              'Error loading content',
                              style: TextStyle(color: Colors.red),
                            ),
                          ),
                        );
                      } else {
                        return SingleChildScrollView(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: snapshot.data!,
                        );
                      }
                    },
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
