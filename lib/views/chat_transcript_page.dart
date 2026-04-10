import 'package:demo_ai_even/models/chat_message_record.dart';
import 'package:demo_ai_even/models/chat_session_record.dart';
import 'package:demo_ai_even/services/chat_history_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class ChatTranscriptPage extends StatefulWidget {
  const ChatTranscriptPage({
    required this.session,
    super.key,
  });

  final ChatSessionRecord session;

  @override
  State<ChatTranscriptPage> createState() => _ChatTranscriptPageState();
}

class _ChatTranscriptPageState extends State<ChatTranscriptPage> {
  late Future<List<ChatMessageRecord>> _transcriptFuture;

  @override
  void initState() {
    super.initState();
    _transcriptFuture = ChatHistoryStore.get.loadTranscript(widget.session.id);
  }

  Future<void> _copyTranscript(List<ChatMessageRecord> messages) async {
    final buffer = StringBuffer();
    for (final message in messages) {
      final speaker = message.role == 'user' ? 'User' : 'Assistant';
      buffer.writeln('$speaker: ${message.text}');
      buffer.writeln();
    }
    await Clipboard.setData(ClipboardData(text: buffer.toString().trim()));
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Transcript copied')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.session.displayTitle),
      ),
      body: FutureBuilder<List<ChatMessageRecord>>(
        future: _transcriptFuture,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final messages = snapshot.data!;
          return Column(
            children: [
              if (messages.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: () => _copyTranscript(messages),
                      icon: const Icon(Icons.copy_rounded, size: 18),
                      label: const Text('Copy transcript'),
                    ),
                  ),
                ),
              Expanded(
                child: ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: messages.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 12),
                  itemBuilder: (context, index) {
                    final message = messages[index];
                    final isUser = message.role == 'user';
                    return Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: isUser
                            ? const Color(0xFF13232D)
                            : const Color(0xFF141A20),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: isUser
                              ? const Color(0xFF2F5B4A)
                              : const Color(0xFF28313A),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            isUser ? 'User' : 'Assistant',
                            style: theme.textTheme.labelLarge?.copyWith(
                              color: isUser
                                  ? const Color(0xFF7FD6A8)
                                  : const Color(0xFF9AB7C8),
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 8),
                          SelectableText(
                            message.text,
                            style: theme.textTheme.bodyLarge?.copyWith(
                              height: 1.45,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
