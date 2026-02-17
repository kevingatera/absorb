import 'package:flutter/material.dart';

class AbsorbTitle extends StatelessWidget {
  final Color? color;

  const AbsorbTitle({super.key, this.color});

  @override
  Widget build(BuildContext context) {
    return Text(
      'A B S O R B',
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
        color: color ?? Theme.of(context).colorScheme.onSurface.withOpacity(0.3),
        letterSpacing: 4,
        fontWeight: FontWeight.w300,
      ),
    );
  }
}
