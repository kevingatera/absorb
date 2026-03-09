import 'package:flutter/material.dart';

class StatusMessageView extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final Color? accentColor;
  final Color? surfaceColor;
  final Color? borderColor;
  final Color? titleColor;
  final Color? messageColor;
  final EdgeInsetsGeometry padding;
  final double maxWidth;

  const StatusMessageView({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
    this.accentColor,
    this.surfaceColor,
    this.borderColor,
    this.titleColor,
    this.messageColor,
    this.padding = const EdgeInsets.all(24),
    this.maxWidth = 420,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final accent = accentColor ?? cs.primary;

    return Center(
      child: Padding(
        padding: padding,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 22),
            decoration: BoxDecoration(
              color: surfaceColor ??
                  cs.surfaceContainerHigh.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: borderColor ?? cs.outlineVariant.withValues(alpha: 0.35),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Icon(icon, size: 26, color: accent),
                ),
                const SizedBox(height: 16),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: tt.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: titleColor ?? cs.onSurface,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: tt.bodyMedium?.copyWith(
                    height: 1.35,
                    color: messageColor ?? cs.onSurfaceVariant,
                  ),
                ),
                if (actionLabel != null && onAction != null) ...[
                  const SizedBox(height: 16),
                  FilledButton.tonal(
                    onPressed: onAction,
                    child: Text(actionLabel!),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
