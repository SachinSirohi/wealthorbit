import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import '../core/core.dart';
import '../core/theme/wo_design.dart';
import 'app_router.dart';

/// Main navigation shell with iOS-style bottom tab bar
class MainShell extends StatefulWidget {
  final Widget child;
  
  const MainShell({super.key, required this.child});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> with TickerProviderStateMixin {
  late AnimationController _fabController;
  late Animation<double> _fabScale;
  
  int _currentIndex = 0;
  
  final List<_NavItem> _navItems = [
    _NavItem(icon: CupertinoIcons.house_fill, label: 'Home', route: AppRoutes.home),
    _NavItem(icon: CupertinoIcons.chart_pie_fill, label: 'Net Worth', route: AppRoutes.netWorth),
    _NavItem(icon: CupertinoIcons.building_2_fill, label: 'Property', route: AppRoutes.realEstate),
    _NavItem(icon: CupertinoIcons.chart_bar_alt_fill, label: 'Invest', route: AppRoutes.investments),
    _NavItem(icon: CupertinoIcons.doc_chart_fill, label: 'Reports', route: AppRoutes.reports),
  ];

  @override
  void initState() {
    super.initState();
    _fabController = AnimationController(
      duration: const Duration(milliseconds: 400),
      vsync: this,
    );
    _fabScale = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _fabController, curve: Curves.elasticOut),
    );
    
    Future.delayed(const Duration(milliseconds: 600), () {
      if (mounted) _fabController.forward();
    });
  }

  @override
  void dispose() {
    _fabController.dispose();
    super.dispose();
  }

  void _onTabTapped(int index) {
    if (_currentIndex != index) {
      HapticFeedback.lightImpact();
      setState(() => _currentIndex = index);
      context.go(_navItems[index].route);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    // Update current index based on location
    _updateCurrentIndex(context);

    // The global quick-add FAB only belongs on Home — feature screens have
    // their own action buttons, and stacking the shell FAB on top of them
    // made buttons like "Add Property" unreachable.
    // Show the global quick-add FAB ONLY when the Home route itself is on
    // screen. Checking the tab index is wrong: pushing /transactions etc.
    // keeps the old index, which floated this FAB over every screen's own
    // Add button.
    final isHome = GoRouterState.of(context).uri.path == AppRoutes.home;

    return Scaffold(
      // No extendBody: screens lay out ABOVE the nav pill, so their own
      // FABs/bottom buttons are never hidden behind it.
      body: widget.child,
      floatingActionButton: isHome
          ? ScaleTransition(
              scale: _fabScale,
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: WoShadows.goldGlow,
                ),
                child: FloatingActionButton(
                  onPressed: () {
                    HapticFeedback.mediumImpact();
                    _showQuickAddMenu(context);
                  },
                  backgroundColor: WoColors.gold,
                  elevation: 0,
                  child: const Icon(CupertinoIcons.add, color: Colors.black, size: 28),
                ),
              ),
            )
          : null,
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      bottomNavigationBar: _buildBottomNav(isDark),
    );
  }
  
  void _updateCurrentIndex(BuildContext context) {
    final location = GoRouterState.of(context).uri.path;
    for (int i = 0; i < _navItems.length; i++) {
      if (location == _navItems[i].route) {
        if (_currentIndex != i) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() => _currentIndex = i);
          });
        }
        break;
      }
    }
  }

  Widget _buildBottomNav(bool isDark) {
    // Floating glass pill (Jupiter-style) with a gold active indicator.
    return SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        decoration: BoxDecoration(
          color: WoColors.bgDeep.withValues(alpha: 0.96),
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: WoColors.borderHi, width: 1),
          boxShadow: WoShadows.navBar,
        ),
        child: Row(
          children: List.generate(_navItems.length, (i) {
            final item = _navItems[i];
            final active = i == _currentIndex;
            return Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _onTabTapped(i),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOut,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  decoration: BoxDecoration(
                    color: active ? WoColors.gold.withValues(alpha: 0.12) : Colors.transparent,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(item.icon, size: 22, color: active ? WoColors.gold : WoColors.textLo),
                      const SizedBox(height: 3),
                      Text(
                        item.label,
                        style: GoogleFonts.inter(
                          fontSize: 9.5,
                          fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                          color: active ? WoColors.gold : WoColors.textLo,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }),
        ),
      ),
    );
  }

  void _showQuickAddMenu(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: isDark ? AppColors.backgroundSecondaryDark : AppColors.backgroundSecondary,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                margin: const EdgeInsets.only(top: 12),
                width: 36, height: 5,
                decoration: BoxDecoration(
                  color: isDark ? AppColors.fillSecondaryDark : AppColors.fillSecondary,
                  borderRadius: BorderRadius.circular(2.5),
                ),
              ),
              const SizedBox(height: 20),
              Text('Quick Add', style: AppTypography.title3(isDark: isDark)),
              const SizedBox(height: 16),
              _QuickAddItem(
                icon: CupertinoIcons.doc_text_fill,
                color: AppColors.systemBlue,
                title: 'Add Transaction',
                subtitle: 'Record income or expense',
                onTap: () {
                  Navigator.pop(ctx);
                  context.push(AppRoutes.transactions);
                },
              ),
              _QuickAddItem(
                icon: CupertinoIcons.arrow_right_arrow_left,
                color: AppColors.systemTeal,
                title: 'Accounts & Transfers',
                subtitle: 'Move money, pay bills',
                onTap: () {
                  Navigator.pop(ctx);
                  context.push(AppRoutes.accounts);
                },
              ),
              _QuickAddItem(
                icon: CupertinoIcons.building_2_fill,
                color: AppColors.systemPurple,
                title: 'Add Property',
                subtitle: 'Add real estate to portfolio',
                onTap: () {
                  Navigator.pop(ctx);
                  context.push(AppRoutes.realEstate);
                },
              ),
              _QuickAddItem(
                icon: CupertinoIcons.chart_bar_alt_fill,
                color: AppColors.systemGreen,
                title: 'Add Investment',
                subtitle: 'Track stocks, mutual funds',
                onTap: () {
                  Navigator.pop(ctx);
                  context.push(AppRoutes.investments);
                },
              ),
              _QuickAddItem(
                icon: CupertinoIcons.flag_fill,
                color: AppColors.systemOrange,
                title: 'Create Goal',
                subtitle: 'Set a financial objective',
                onTap: () {
                  Navigator.pop(ctx);
                  context.push(AppRoutes.goals);
                },
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

}

class _NavItem {
  final IconData icon;
  final String label;
  final String route;

  _NavItem({required this.icon, required this.label, required this.route});
}

class _QuickAddItem extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _QuickAddItem({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          HapticFeedback.lightImpact();
          onTap();
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Container(
                width: 44, height: 44,
                decoration: BoxDecoration(color: color.withAlpha(38), borderRadius: BorderRadius.circular(12)),
                child: Icon(icon, color: color, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: AppTypography.headline(isDark: isDark)),
                    Text(subtitle, style: AppTypography.footnote(isDark: isDark)),
                  ],
                ),
              ),
              Icon(CupertinoIcons.chevron_right, size: 18, color: isDark ? AppColors.textQuaternaryDark : AppColors.textQuaternary),
            ],
          ),
        ),
      ),
    );
  }
}
