import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/library_provider.dart';

/// Maps Audiobookshelf server library icon names to Material Icons.
/// ABS uses Material Symbols names as its icon identifiers.
IconData _absIconToMaterial(String? icon, String? mediaType) {
  switch (icon) {
    case 'audiobookshelf':
      return Icons.headphones_rounded;
    case 'database':
      return Icons.storage_rounded;
    case 'podcast':
      return Icons.podcasts_rounded;
    case 'book-open':
      return Icons.menu_book_rounded;
    case 'music':
      return Icons.music_note_rounded;
    case 'radio':
      return Icons.radio_rounded;
    case 'book-2': // alternate book icon in some ABS versions
      return Icons.auto_stories_rounded;
    case 'hat-wizard':
      return Icons.auto_fix_high_rounded;
    case 'atom':
      return Icons.science_rounded;
    case 'rocket':
      return Icons.rocket_launch_rounded;
    case 'microphone':
    case 'microphone-alt':
      return Icons.mic_rounded;
    default:
      // Fallback based on media type
      return mediaType == 'podcast'
          ? Icons.podcasts_rounded
          : Icons.auto_stories_rounded;
  }
}

class LibrarySelectorButton extends StatelessWidget {
  const LibrarySelectorButton({super.key});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.swap_horiz_rounded),
      tooltip: 'Switch library',
      onPressed: () => _showLibraryPicker(context),
    );
  }

  void _showLibraryPicker(BuildContext context) {
    final lib = context.read<LibraryProvider>();
    final cs = Theme.of(context).colorScheme;

    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                child: Text(
                  'Select Library',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ),
              const SizedBox(height: 8),
              ...lib.libraries
                .where((library) => (library['mediaType'] as String? ?? 'book') != 'podcast')
                .map((library) {
                final id = library['id'] as String;
                final name = library['name'] as String? ?? 'Library';
                final icon = library['icon'] as String?;
                final mediaType = library['mediaType'] as String? ?? 'book';
                final isSelected = id == lib.selectedLibraryId;

                return ListTile(
                  leading: Icon(
                    _absIconToMaterial(icon, mediaType),
                    color: isSelected ? cs.primary : cs.onSurfaceVariant,
                  ),
                  title: Text(name),
                  trailing: isSelected
                      ? Icon(Icons.check_circle_rounded,
                          color: cs.primary)
                      : null,
                  selected: isSelected,
                  onTap: () {
                    Navigator.pop(ctx);
                    if (!isSelected) {
                      lib.selectLibrary(id);
                    }
                  },
                );
              }),
              const SizedBox(height: 16),
            ],
          ),
        );
      },
    );
  }
}
