import 'package:flutter/material.dart';

class AppBackground extends StatelessWidget {
  const AppBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Stack(
      children: [
        const Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFFF4F6F0), Color(0xFFE7EEF1)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
          ),
        ),
        IgnorePointer(
          child: Stack(
            children: [
              Positioned(
                top: -80,
                right: -60,
                child: _GlowBlob(
                  color: Color(0xFF1B7F6E),
                  size: 220,
                ),
              ),
              Positioned(
                bottom: -120,
                left: -40,
                child: _GlowBlob(
                  color: Color(0xFF0F4C5C),
                  size: 260,
                ),
              ),
              Positioned(
                top: 220,
                left: -30,
                child: _GlowBlob(
                  color: colorScheme.tertiary.withOpacity(0.35),
                  size: 160,
                ),
              ),
            ],
          ),
        ),
        Positioned.fill(child: child),
      ],
    );
  }
}

class _GlowBlob extends StatelessWidget {
  const _GlowBlob({required this.color, required this.size});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [color.withOpacity(0.35), color.withOpacity(0)],
        ),
      ),
    );
  }
}
