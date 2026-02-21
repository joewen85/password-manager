import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../theme/motion_tokens.dart';

class FadeSlide extends StatefulWidget {
  const FadeSlide({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    this.duration = defaultDuration,
    this.offset = const Offset(0, 16),
    this.enable = !kDebugMode,
  });

  static const Duration defaultDuration = Duration(milliseconds: 480);

  final Widget child;
  final Duration delay;
  final Duration duration;
  final Offset offset;
  final bool enable;

  @override
  State<FadeSlide> createState() => _FadeSlideState();
}

class _FadeSlideState extends State<FadeSlide>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;
  Animation<double>? _opacity;
  Animation<Offset>? _slide;
  Timer? _delayTimer;

  @override
  void initState() {
    super.initState();
    if (!widget.enable) {
      return;
    }
    final isAndroid = defaultTargetPlatform == TargetPlatform.android;
    final duration = isAndroid && widget.duration == FadeSlide.defaultDuration
        ? MotionTokens.medium2
        : widget.duration;
    _controller = AnimationController(vsync: this, duration: duration);
    final curve = CurvedAnimation(
      parent: _controller!,
      curve: isAndroid ? MotionTokens.emphasizedDecelerate : Curves.easeOutCubic,
    );
    _opacity = Tween<double>(begin: 0, end: 1).animate(curve);
    _slide = Tween<Offset>(begin: widget.offset, end: Offset.zero).animate(curve);
    if (widget.delay == Duration.zero) {
      _controller!.forward();
    } else {
      _delayTimer = Timer(widget.delay, () {
        if (mounted) {
          _controller?.forward();
        }
      });
    }
  }

  @override
  void dispose() {
    _delayTimer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final disableAnimations =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (!widget.enable || disableAnimations) {
      return widget.child;
    }
    return FadeTransition(
      opacity: _opacity!,
      child: SlideTransition(
        position: _slide!,
        child: widget.child,
      ),
    );
  }
}
