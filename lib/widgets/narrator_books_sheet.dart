import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import '../providers/library_provider.dart';
import 'library_search_results.dart';
import 'status_message_view.dart';

void showNarratorBooksSheet(BuildContext context,
    {required String narratorName}) {
  FocusManager.instance.primaryFocus?.unfocus();
  final auth = context.read<AuthProvider>();
  final lib = context.read<LibraryProvider>();
  final api = auth.apiService;
  if (api == null || lib.selectedLibraryId == null || narratorName.isEmpty)
    return;

  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.05,
      snap: true,
      maxChildSize: 0.9,
      expand: false,
      builder: (ctx, scrollController) => NarratorBooksSheet(
        libraryId: lib.selectedLibraryId!,
        narratorName: narratorName,
        serverUrl: auth.serverUrl,
        token: auth.token,
        scrollController: scrollController,
      ),
    ),
  );
}

class NarratorBooksSheet extends StatefulWidget {
  final String libraryId;
  final String narratorName;
  final String? serverUrl;
  final String? token;
  final ScrollController scrollController;

  const NarratorBooksSheet({
    super.key,
    required this.libraryId,
    required this.narratorName,
    required this.serverUrl,
    required this.token,
    required this.scrollController,
  });

  @override
  State<NarratorBooksSheet> createState() => _NarratorBooksSheetState();
}

class _NarratorBooksSheetState extends State<NarratorBooksSheet> {
  List<Map<String, dynamic>> _books = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadBooks();
  }

  Future<void> _loadBooks() async {
    final auth = context.read<AuthProvider>();
    final api = auth.apiService;
    if (api == null) {
      if (mounted) setState(() => _isLoading = false);
      return;
    }

    try {
      final results = await api.getBooksByNarrator(
        widget.libraryId,
        widget.narratorName,
      );
      if (!mounted) return;
      setState(() {
        _books = results.whereType<Map<String, dynamic>>().toList();
        _isLoading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
          child: Row(
            children: [
              Icon(Icons.record_voice_over_rounded,
                  size: 20, color: cs.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.narratorName,
                  style: tt.titleLarge?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
        if (_isLoading)
          const Expanded(child: Center(child: CircularProgressIndicator()))
        else if (_books.isEmpty)
          Expanded(
            child: StatusMessageView(
              icon: Icons.record_voice_over_rounded,
              title: 'No books found for ${widget.narratorName}',
              message:
                  'This narrator does not have any matching books in the current library yet.',
            ),
          )
        else
          Expanded(
            child: ListView.builder(
              controller: widget.scrollController,
              padding: EdgeInsets.fromLTRB(
                  16, 0, 16, 24 + MediaQuery.of(context).viewPadding.bottom),
              itemCount: _books.length,
              itemBuilder: (context, index) {
                return BookResultTile(
                  item: _books[index],
                  serverUrl: widget.serverUrl,
                  token: widget.token,
                );
              },
            ),
          ),
      ],
    );
  }
}
