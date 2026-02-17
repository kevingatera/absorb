import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/library_provider.dart';

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
              ...lib.libraries.map((library) {
                final id = library['id'] as String;
                final name = library['name'] as String? ?? 'Library';
                final mediaType = library['mediaType'] as String? ?? 'book';
                final isSelected = id == lib.selectedLibraryId;

                return ListTile(
                  leading: Icon(
                    mediaType == 'podcast'
                        ? Icons.podcasts_rounded
                        : Icons.auto_stories_rounded,
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
