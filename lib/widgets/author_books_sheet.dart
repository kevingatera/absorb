import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import 'library_search_results.dart';
import 'status_message_view.dart';

class AuthorBooksSheet extends StatefulWidget {
  final String libraryId;
  final String authorId;
  final String authorName;
  final String? serverUrl;
  final String? token;
  final ScrollController scrollController;

  const AuthorBooksSheet({
    super.key,
    required this.libraryId,
    required this.authorId,
    required this.authorName,
    required this.serverUrl,
    required this.token,
    required this.scrollController,
  });

  @override
  State<AuthorBooksSheet> createState() => _AuthorBooksSheetState();
}

class _AuthorBooksSheetState extends State<AuthorBooksSheet> {
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
      // Use audiobookshelf filter: authors.<base64(authorId)>
      final filterValue = base64Encode(utf8.encode(widget.authorId));
      final cleanUrl = (auth.serverUrl ?? '').endsWith('/')
          ? auth.serverUrl!.substring(0, auth.serverUrl!.length - 1)
          : auth.serverUrl!;
      final url = '$cleanUrl/api/libraries/${widget.libraryId}/items'
          '?filter=authors.$filterValue&sort=media.metadata.title&limit=200&collapseseries=0';

      final response = await http.get(
        Uri.parse(url),
        headers: {
          'Authorization': 'Bearer ${auth.token}',
        },
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200 && mounted) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final results = (data['results'] as List<dynamic>?) ?? [];
        setState(() {
          _books = results.whereType<Map<String, dynamic>>().toList();
          _isLoading = false;
        });
      } else if (mounted) {
        setState(() => _isLoading = false);
      }
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
              Icon(Icons.person_rounded, size: 20, color: cs.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(widget.authorName,
                    style:
                        tt.titleLarge?.copyWith(fontWeight: FontWeight.w600)),
              ),
            ],
          ),
        ),
        if (_isLoading)
          const Expanded(child: Center(child: CircularProgressIndicator()))
        else if (_books.isEmpty)
          Expanded(
            child: StatusMessageView(
              icon: Icons.person_search_rounded,
              title: 'No books found for ${widget.authorName}',
              message:
                  'This author does not have any matching books in the current library yet.',
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
