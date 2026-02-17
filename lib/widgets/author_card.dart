import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../providers/auth_provider.dart';

class AuthorCard extends StatelessWidget {
  final Map<String, dynamic> author;

  const AuthorCard({super.key, required this.author});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final auth = context.read<AuthProvider>();

    final name = author['name'] as String? ?? 'Unknown';
    final authorId = author['id'] as String? ?? '';

    String? imageUrl;
    if (authorId.isNotEmpty && auth.serverUrl != null && auth.token != null) {
      imageUrl =
          '${auth.serverUrl}/api/authors/$authorId/image?width=200&token=${auth.token}';
    }

    return InkWell(
      onTap: () {}, // TODO: navigate to author
      borderRadius: BorderRadius.circular(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Circular avatar
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: cs.secondaryContainer,
            ),
            clipBehavior: Clip.antiAlias,
            child: imageUrl != null
                ? CachedNetworkImage(
                    imageUrl: imageUrl,
                    fit: BoxFit.cover,
                    placeholder: (_, __) => _placeholder(cs),
                    errorWidget: (_, __, ___) => _placeholder(cs),
                  )
                : _placeholder(cs),
          ),
          const SizedBox(height: 8),
          // Name
          SizedBox(
            width: 100,
            child: Text(
              name,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: tt.labelMedium?.copyWith(
                fontWeight: FontWeight.w500,
                color: cs.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _placeholder(ColorScheme cs) {
    return Center(
      child: Icon(
        Icons.person_rounded,
        size: 32,
        color: cs.onSecondaryContainer.withOpacity(0.5),
      ),
    );
  }
}
