import 'dart:ui';

import 'package:aqluse_website/generated/localization/localizations.dart';
import 'package:aqluse_website/navigation/app_route.dart';
import 'package:aqluse_website/navigation/app_router_delegate.dart';
import 'package:aqluse_website/widgets/bubble_animation/liquid_bubbles.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:url_launcher/url_launcher.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  ThemeData get theme => Theme.of(context);

  bool get isDark => theme.brightness == Brightness.dark;

  S get s => S.of(context);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // TODO: Bubble's view must be present at every page + share current state between pages.
      body: LiquidBubbles(
        child: Center(
          child: GlassContainer(
            child: Column(
              mainAxisSize: .min,
              crossAxisAlignment: .center,
              children: [
                Text(
                  s.appTitle,
                  textAlign: .center,
                  style: theme.textTheme.headlineLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 600),
                  child: Text(
                    s.homeTagline,
                    textAlign: .center,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.8),
                      height: 1.5,
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                Wrap(
                  crossAxisAlignment: .center,
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    _ResourceChip(
                      label: 'GitHub',
                      icon: SvgPicture.asset(
                        isDark
                            ? 'assets/icons/branding/github/GitHub_Invertocat_White.svg'
                            : 'assets/icons/branding/github/GitHub_Invertocat_Black.svg',
                      ),
                      onTap: () =>
                          launchUrl(Uri.parse('https://github.com/Aqluse')),
                    ),
                    _ResourceChip(
                      label: 'Telegram',
                      icon: SvgPicture.asset(
                        'assets/icons/branding/telegram/Logo.svg',
                      ),
                      onTap: () => launchUrl(Uri.parse('https://t.me/aqluse')),
                    ),
                    _ResourceChip(
                      label: 'HeadHunter',
                      icon: SvgPicture.asset(
                        'assets/icons/branding/headhunter/hh_logo_red.svg',
                      ),
                      onTap: () => launchUrl(
                        Uri.parse(
                          'https://hh.ru/resume/d0693619ff1124d4400039ed1f5439444d6f58',
                        ),
                      ),
                    ),
                    _ResourceChip(
                      label: 'LinkedIn',
                      icon: SvgPicture.asset(
                        'assets/icons/branding/linkedin/LinkedIn.svg',
                      ),
                      onTap: () {},
                    ),
                    // TODO: Я бы сначала деловую почту завел, прежде чем добавлять
                    /*_ResourceChip(
                      label: 'E-mail',
                      icon: Icons.email_outlined,
                      onTap: () {},
                    ),*/
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => AppRouterDelegate.of(context).goTo(SecondRouteTest()),
        child: const Icon(Icons.add),
      ),
    );
  }
}

class _ResourceChip extends StatelessWidget {
  const _ResourceChip({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final Widget icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: label,
      child: IconButton(
        onPressed: onTap,
        icon: SizedBox.square(dimension: 36, child: icon),
        style: OutlinedButton.styleFrom(
          padding: .symmetric(horizontal: 16, vertical: 12),
          shape: RoundedRectangleBorder(borderRadius: .circular(12)),
        ),
      ),
    );
  }
}

class GlassContainer extends StatelessWidget {
  final Widget child;
  final double blur;
  final BorderRadius? borderRadius;

  const GlassContainer({
    super.key,
    required this.child,
    this.blur = 6.0,
    this.borderRadius,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveRadius = borderRadius ?? BorderRadius.circular(16);

    return ClipRRect(
      // 1. Обрезаем размытие по границам виджета
      borderRadius: effectiveRadius,
      child: BackdropFilter(
        // 2. Применяем размытие к заднему плану
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: DecoratedBox(
          // 3. Полупрозрачная подложка поверх размытия
          decoration: BoxDecoration(
            borderRadius: effectiveRadius,
            gradient: LinearGradient(
              begin: .topLeft,
              end: .bottomRight,
              colors: [
                Colors.white.withValues(alpha: 0.2),
                Colors.white.withValues(alpha: 0.03),
              ],
            ),
          ),
          child: Padding(padding: .all(24), child: child),
        ),
      ),
    );
  }
}
