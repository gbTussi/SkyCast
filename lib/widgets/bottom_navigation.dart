import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class BottomNavigation extends StatelessWidget {
  const BottomNavigation({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final String location = GoRouterState.of(context).uri.path;

    final List<Map<String, dynamic>> navItems = [
      {'icon': Icons.person_outline, 'label': 'Perfil', 'path': '/profile'},
      {'icon': Icons.home_outlined, 'label': 'Início', 'path': '/home'},
      {'icon': Icons.directions_outlined, 'label': 'Viagem', 'path': '/route'},
    ];

    int currentIndex = navItems.indexWhere((item) => item['path'] == location);
    if (currentIndex == -1) {
      currentIndex = 0;
    }

    return Container(
      decoration: BoxDecoration(
        boxShadow: [
          BoxShadow(
              color: isDark ? Colors.black54 : Colors.black12, blurRadius: 10),
        ],
      ),
      child: BottomNavigationBar(
        currentIndex: currentIndex,
        onTap: (index) => context.go(navItems[index]['path'] as String),
        type: BottomNavigationBarType.fixed,
        backgroundColor: isDark ? const Color(0xFF0F172A) : Colors.white,
        selectedItemColor: Colors.blue[600],
        unselectedItemColor:
            isDark ? const Color(0xFF9CA3AF) : Colors.grey[500],
        selectedLabelStyle: const TextStyle(
          fontWeight: FontWeight.bold,
          fontSize: 12,
        ),
        unselectedLabelStyle: const TextStyle(
          fontWeight: FontWeight.w500,
          fontSize: 12,
        ),
        items: navItems.map((item) {
          return BottomNavigationBarItem(
            icon: Icon(item['icon'] as IconData),
            label: item['label'] as String,
          );
        }).toList(),
      ),
    );
  }
}
