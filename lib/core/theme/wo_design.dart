import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// ═══════════════════════════════════════════════════════════════════════════
/// WealthOrbit 3.0 design system
///
/// Direction: Cred's dark neumorphic depth + Jupiter's clean minimalism +
/// Monarch's data-rich dashboard. One source of truth for color, depth,
/// type and the reusable building blocks every screen composes from.
/// ═══════════════════════════════════════════════════════════════════════════

/// Theme selection: System follows the OS, or force Light/Dark.
enum WoThemeMode { system, light, dark }

/// Global theme switchboard. Screens read WoColors getters, which resolve
/// against the active palette; bump [revision] to rebuild the app.
class WoTheme {
  WoTheme._();

  static WoThemeMode mode = WoThemeMode.system;
  static bool isDark = true;

  /// Incremented on every theme change; the app root listens and rebuilds.
  static final ValueNotifier<int> revision = ValueNotifier(0);

  static void apply(WoThemeMode m, Brightness platform) {
    mode = m;
    isDark = switch (m) {
      WoThemeMode.system => platform == Brightness.dark,
      WoThemeMode.light => false,
      WoThemeMode.dark => true,
    };
    revision.value++;
  }
}

/// Dark palette — WO 3.0 (Cred-inspired near-black + gold).
class _Dark {
  static const bg = Color(0xFF0A0C12);
  static const bgDeep = Color(0xFF07090E);
  static const surface = Color(0xFF151926);
  static const surfaceHi = Color(0xFF1C2231);
  static const surfaceLo = Color(0xFF10141E);
  static const inputFill = Color(0xFF10141E);
  static const border = Color(0x0FFFFFFF);
  static const borderHi = Color(0x1FFFFFFF);
  static const gold = Color(0xFF55E6A5); // brand green (sachinsirohi.com accent)
  static const goldDeep = Color(0xFF2BBD7E);
  static const goldDim = Color(0x3355E6A5);
  static const indigo = Color(0xFF7C6FF0);
  static const blue = Color(0xFF4D9FFF);
  static const mint = Color(0xFF4ADE80);
  static const red = Color(0xFFFF6B6B);
  static const orange = Color(0xFFFFB454);
  static const teal = Color(0xFF45D4C8);
  static const textHi = Color(0xFFF4F6FB);
  static const textMid = Color(0xFF9AA3B5);
  static const textLo = Color(0xFF5C6578);
}

/// Light palette — Jupiter-inspired clean minimalism.
class _Light {
  static const bg = Color(0xFFF5F6FA);
  static const bgDeep = Color(0xFFFFFFFF);
  static const surface = Color(0xFFFFFFFF);
  static const surfaceHi = Color(0xFFFFFFFF);
  static const surfaceLo = Color(0xFFF0F2F7);
  static const inputFill = Color(0xFFEDF0F6);
  static const border = Color(0x14000000); // black 8%
  static const borderHi = Color(0x24000000); // black 14%
  static const gold = Color(0xFF12A368); // brand green, readable on light surfaces
  static const goldDeep = Color(0xFF0B7A49);
  static const goldDim = Color(0x3312A368);
  static const indigo = Color(0xFF5B4FD8);
  static const blue = Color(0xFF2E7CE8);
  static const mint = Color(0xFF14935B);
  static const red = Color(0xFFDC4A4E);
  static const orange = Color(0xFFD98414);
  static const teal = Color(0xFF128F84);
  static const textHi = Color(0xFF14161D);
  static const textMid = Color(0xFF4C5366);
  static const textLo = Color(0xFF8A91A5);
}

class WoColors {
  WoColors._();

  // Canvas
  static Color get bg => WoTheme.isDark ? _Dark.bg : _Light.bg;
  static Color get bgDeep => WoTheme.isDark ? _Dark.bgDeep : _Light.bgDeep;

  // Surfaces (cards float on the canvas via gradient + dual shadow)
  static Color get surface => WoTheme.isDark ? _Dark.surface : _Light.surface;
  static Color get surfaceHi => WoTheme.isDark ? _Dark.surfaceHi : _Light.surfaceHi;
  static Color get surfaceLo => WoTheme.isDark ? _Dark.surfaceLo : _Light.surfaceLo;
  static Color get inputFill => WoTheme.isDark ? _Dark.inputFill : _Light.inputFill;

  // Strokes
  static Color get border => WoTheme.isDark ? _Dark.border : _Light.border;
  static Color get borderHi => WoTheme.isDark ? _Dark.borderHi : _Light.borderHi;

  // Brand — premium gold
  static Color get gold => WoTheme.isDark ? _Dark.gold : _Light.gold;
  static Color get goldDeep => WoTheme.isDark ? _Dark.goldDeep : _Light.goldDeep;
  static Color get goldDim => WoTheme.isDark ? _Dark.goldDim : _Light.goldDim;

  // Functional accents
  static Color get indigo => WoTheme.isDark ? _Dark.indigo : _Light.indigo;
  static Color get blue => WoTheme.isDark ? _Dark.blue : _Light.blue;
  static Color get mint => WoTheme.isDark ? _Dark.mint : _Light.mint;
  static Color get red => WoTheme.isDark ? _Dark.red : _Light.red;
  static Color get orange => WoTheme.isDark ? _Dark.orange : _Light.orange;
  static Color get teal => WoTheme.isDark ? _Dark.teal : _Light.teal;

  // Text
  static Color get textHi => WoTheme.isDark ? _Dark.textHi : _Light.textHi;
  static Color get textMid => WoTheme.isDark ? _Dark.textMid : _Light.textMid;
  static Color get textLo => WoTheme.isDark ? _Dark.textLo : _Light.textLo;

  /// Income/expense semantic colors.
  static Color get income => mint;
  static Color get expense => red;
}

class WoRadius {
  WoRadius._();
  static const card = 22.0;
  static const control = 14.0;
  static const chip = 100.0;
}

class WoShadows {
  WoShadows._();

  /// Neumorphic card depth: strong drop below-right, faint light above-left.
  static List<BoxShadow> get card => WoTheme.isDark
      ? const [
          BoxShadow(color: Color(0x73000000), blurRadius: 22, offset: Offset(0, 10)),
          BoxShadow(color: Color(0x08FFFFFF), blurRadius: 10, offset: Offset(-2, -3)),
        ]
      : const [
          BoxShadow(color: Color(0x14101828), blurRadius: 18, offset: Offset(0, 8)),
        ];

  static List<BoxShadow> get goldGlow => WoTheme.isDark
      ? const [
          BoxShadow(color: Color(0x4055E6A5), blurRadius: 32, offset: Offset(0, 8)),
          BoxShadow(color: Color(0x73000000), blurRadius: 22, offset: Offset(0, 12)),
        ]
      : const [
          BoxShadow(color: Color(0x2E12A368), blurRadius: 26, offset: Offset(0, 8)),
          BoxShadow(color: Color(0x18101828), blurRadius: 18, offset: Offset(0, 8)),
        ];

  static List<BoxShadow> get navBar => WoTheme.isDark
      ? const [BoxShadow(color: Color(0xB3000000), blurRadius: 28, offset: Offset(0, 12))]
      : const [BoxShadow(color: Color(0x22101828), blurRadius: 24, offset: Offset(0, 10))];
}

/// Card surface: subtle top-left→bottom-right luminance falloff sells the
/// neumorphic depth without heavy borders.
BoxDecoration woCard({double radius = WoRadius.card, bool goldGlow = false, Color? tint}) {
  return BoxDecoration(
    gradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        tint != null ? Color.alphaBlend(tint.withValues(alpha: 0.10), WoColors.surfaceHi) : WoColors.surfaceHi,
        tint != null ? Color.alphaBlend(tint.withValues(alpha: 0.04), WoColors.surfaceLo) : WoColors.surfaceLo,
      ],
    ),
    borderRadius: BorderRadius.circular(radius),
    border: Border.all(color: goldGlow ? WoColors.goldDim : WoColors.border, width: 1),
    boxShadow: goldGlow ? WoShadows.goldGlow : WoShadows.card,
  );
}

/// Flat inset surface (inputs, wells) — the "pressed" half of neumorphism.
BoxDecoration woWell({double radius = WoRadius.control}) {
  return BoxDecoration(
    color: WoColors.inputFill,
    borderRadius: BorderRadius.circular(radius),
    border: Border.all(color: WoColors.border, width: 1),
  );
}

class WoText {
  WoText._();

  /// Big money numerals (Cred-style hero).
  static TextStyle hero({Color? color}) => GoogleFonts.poppins(
      fontSize: 38, fontWeight: FontWeight.w700, color: color ?? WoColors.textHi, letterSpacing: -1.2, height: 1.05);

  static TextStyle display({Color? color}) =>
      GoogleFonts.poppins(fontSize: 26, fontWeight: FontWeight.w700, color: color ?? WoColors.textHi, letterSpacing: -0.6);

  static TextStyle title({Color? color}) =>
      GoogleFonts.poppins(fontSize: 17, fontWeight: FontWeight.w600, color: color ?? WoColors.textHi);

  static TextStyle subtitle({Color? color}) =>
      GoogleFonts.poppins(fontSize: 14.5, fontWeight: FontWeight.w600, color: color ?? WoColors.textHi);

  static TextStyle body({Color? color}) =>
      GoogleFonts.inter(fontSize: 13.5, fontWeight: FontWeight.w400, color: color ?? WoColors.textMid, height: 1.45);

  static TextStyle bodyHi({Color? color}) =>
      GoogleFonts.inter(fontSize: 13.5, fontWeight: FontWeight.w500, color: color ?? WoColors.textHi);

  static TextStyle num({Color? color, double size = 15}) => GoogleFonts.poppins(
      fontSize: size, fontWeight: FontWeight.w600, color: color ?? WoColors.textHi, letterSpacing: -0.2);

  static TextStyle caption({Color? color}) =>
      GoogleFonts.inter(fontSize: 11.5, fontWeight: FontWeight.w400, color: color ?? WoColors.textMid);

  /// Monarch-style section label: small caps, tracked out.
  static TextStyle label({Color? color}) => GoogleFonts.inter(
      fontSize: 11, fontWeight: FontWeight.w700, color: color ?? WoColors.textLo, letterSpacing: 1.4);
}

class WoButtons {
  WoButtons._();

  static ButtonStyle get primary => ElevatedButton.styleFrom(
    backgroundColor: WoColors.gold,
    foregroundColor: Colors.black,
    disabledBackgroundColor: const Color(0xFF2A3142),
    disabledForegroundColor: WoColors.textLo,
    elevation: 0,
    padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(WoRadius.control)),
    textStyle: GoogleFonts.poppins(fontWeight: FontWeight.w600, fontSize: 15),
  );

  static ButtonStyle get danger => ElevatedButton.styleFrom(
    backgroundColor: WoColors.red,
    foregroundColor: Colors.white,
    elevation: 0,
    padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(WoRadius.control)),
    textStyle: GoogleFonts.poppins(fontWeight: FontWeight.w600, fontSize: 15),
  );

  static ButtonStyle get ghost => OutlinedButton.styleFrom(
    foregroundColor: WoColors.textMid,
    side: BorderSide(color: WoColors.borderHi),
    padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(WoRadius.control)),
    textStyle: GoogleFonts.poppins(fontWeight: FontWeight.w500, fontSize: 14),
  );
}

InputDecoration woInput(String label, {String? hint, IconData? icon}) => InputDecoration(
      labelText: label,
      hintText: hint,
      labelStyle: GoogleFonts.inter(color: WoColors.textLo, fontSize: 13),
      hintStyle: GoogleFonts.inter(color: WoColors.textLo.withValues(alpha: 0.6), fontSize: 13),
      prefixIcon: icon != null ? Icon(icon, color: WoColors.textLo, size: 19) : null,
      filled: true,
      fillColor: WoColors.inputFill,
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(WoRadius.control),
        borderSide: BorderSide(color: WoColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(WoRadius.control),
        borderSide: BorderSide(color: WoColors.gold, width: 1.2),
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(WoRadius.control),
        borderSide: BorderSide(color: WoColors.border),
      ),
    );

// ═══════════════════════════════════════════════════════════════════════════
// REUSABLE WIDGETS
// ═══════════════════════════════════════════════════════════════════════════

/// Standard elevated card.
class WoCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final VoidCallback? onTap;
  final bool goldGlow;
  final Color? tint;
  final double radius;

  const WoCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
    this.margin,
    this.onTap,
    this.goldGlow = false,
    this.tint,
    this.radius = WoRadius.card,
  });

  @override
  Widget build(BuildContext context) {
    final card = Container(
      margin: margin,
      padding: padding,
      decoration: woCard(radius: radius, goldGlow: goldGlow, tint: tint),
      child: child,
    );
    if (onTap == null) return card;
    return GestureDetector(behavior: HitTestBehavior.opaque, onTap: onTap, child: card);
  }
}

/// Monarch-style section header: `OVERVIEW            See all ›`
class WoSectionHeader extends StatelessWidget {
  final String label;
  final String? action;
  final VoidCallback? onAction;
  final EdgeInsetsGeometry padding;

  const WoSectionHeader(
    this.label, {
    super.key,
    this.action,
    this.onAction,
    this.padding = const EdgeInsets.fromLTRB(2, 8, 2, 12),
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Row(
        children: [
          Expanded(child: Text(label.toUpperCase(), style: WoText.label())),
          if (action != null)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onAction,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(action!, style: GoogleFonts.inter(color: WoColors.gold, fontSize: 12.5, fontWeight: FontWeight.w600)),
                  Icon(Icons.chevron_right, color: WoColors.gold, size: 16),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Tinted rounded icon bubble (transaction categories, list leading icons).
class WoIconBubble extends StatelessWidget {
  final IconData icon;
  final Color? color;
  final double size;

  const WoIconBubble(this.icon, {super.key, this.color, this.size = 42});

  @override
  Widget build(BuildContext context) {
    final c = color ?? WoColors.gold;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [c.withValues(alpha: 0.22), c.withValues(alpha: 0.08)],
        ),
        borderRadius: BorderRadius.circular(size * 0.32),
        border: Border.all(color: c.withValues(alpha: 0.25), width: 0.8),
      ),
      child: Icon(icon, color: c, size: size * 0.46),
    );
  }
}

/// Small status / metadata pill.
class WoChip extends StatelessWidget {
  final String text;
  final Color? color;
  final IconData? icon;

  const WoChip(this.text, {super.key, this.color, this.icon});

  @override
  Widget build(BuildContext context) {
    final c = color ?? WoColors.textMid;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(WoRadius.chip),
        border: Border.all(color: c.withValues(alpha: 0.3), width: 0.6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, color: c, size: 12),
            const SizedBox(width: 4),
          ],
          Text(text,
              style: GoogleFonts.inter(color: c, fontSize: 11, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

/// Friendly empty state: icon, title, one-line hint, optional CTA.
class WoEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String hint;
  final String? ctaLabel;
  final VoidCallback? onCta;

  const WoEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.hint,
    this.ctaLabel,
    this.onCta,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [WoColors.surfaceHi, WoColors.surfaceLo],
                ),
                shape: BoxShape.circle,
                border: Border.all(color: WoColors.border),
                boxShadow: WoShadows.card,
              ),
              child: Icon(icon, color: WoColors.gold, size: 36),
            ),
            const SizedBox(height: 20),
            Text(title, style: WoText.title(), textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(hint, style: WoText.body(), textAlign: TextAlign.center),
            if (ctaLabel != null) ...[
              const SizedBox(height: 24),
              ElevatedButton(onPressed: onCta, style: WoButtons.primary, child: Text(ctaLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}

/// Inline notice (success / warning / error) — replaces ad-hoc snack containers.
class WoNotice extends StatelessWidget {
  final String text;
  final Color? color;
  final IconData icon;

  const WoNotice(this.text, {super.key, this.color, this.icon = Icons.check_circle});

  @override
  Widget build(BuildContext context) {
    final c = color ?? WoColors.mint;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(WoRadius.control),
        border: Border.all(color: c.withValues(alpha: 0.3), width: 0.8),
      ),
      child: Row(
        children: [
          Icon(icon, color: c, size: 18),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: GoogleFonts.inter(color: c, fontSize: 13))),
        ],
      ),
    );
  }
}

/// Drag handle for bottom sheets.
class WoSheetHandle extends StatelessWidget {
  const WoSheetHandle({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 42,
        height: 4,
        margin: const EdgeInsets.only(top: 4, bottom: 18),
        decoration: BoxDecoration(
          color: WoColors.borderHi,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}

/// Standard bottom-sheet scaffold: dark surface, rounded top, handle.
class WoSheet extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;

  const WoSheet({super.key, required this.child, this.padding = const EdgeInsets.fromLTRB(24, 8, 24, 24)});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      decoration: BoxDecoration(
        color: WoColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        border: Border(top: BorderSide(color: WoColors.borderHi, width: 1)),
      ),
      child: Padding(
        padding: padding,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [const WoSheetHandle(), child],
        ),
      ),
    );
  }
}
