import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../core/theme/wo_design.dart';
import '../../../data/services/gemini_service.dart';
import '../../../data/repositories/app_repository.dart';

/// AI Chat Screen - Conversational AI for financial insights
class AiChatScreen extends StatefulWidget {
  final AppRepository repository;
  final GeminiService geminiService;
  
  const AiChatScreen({
    super.key,
    required this.repository,
    required this.geminiService,
  });
  
  @override
  State<AiChatScreen> createState() => _AiChatScreenState();
}

class _AiChatScreenState extends State<AiChatScreen> {
  final TextEditingController _messageController = TextEditingController();
  final List<ChatMessage> _messages = [];
  final ScrollController _scrollController = ScrollController();
  bool _isLoading = false;
  String? _userContext;
  
  @override
  void initState() {
    super.initState();
    _buildUserContext();
    _addWelcomeMessage();
  }
  
  Future<void> _buildUserContext() async {
    try {
      final netWorth = await widget.repository.getNetWorth();
      final monthlyIncome = await widget.repository.getTotalIncomeByMonth(DateTime.now().year, DateTime.now().month);
      final monthlyExpenses = await widget.repository.getTotalExpensesByMonth(DateTime.now().year, DateTime.now().month);
      final emergencyMonths = await widget.repository.getEmergencyFundMonths();
      final assets = await widget.repository.getAllAssets();
      final goals = await widget.repository.getAllGoals();
      final liabilities = await widget.repository.getTotalLiabilities();
      
      _userContext = '''
User Financial Summary:
- Net Worth: AED ${netWorth.toStringAsFixed(0)}
- Monthly Income: AED ${monthlyIncome.toStringAsFixed(0)}
- Monthly Expenses: AED ${monthlyExpenses.toStringAsFixed(0)}
- Emergency Fund: $emergencyMonths months
- Total Assets: ${assets.length}
- Active Goals: ${goals.where((g) => g.status == 'active').length}
- Total Liabilities: AED ${liabilities.toStringAsFixed(0)}
''';
    } catch (e) {
      _userContext = 'Unable to fetch user data';
    }
  }
  
  void _addWelcomeMessage() {
    _messages.add(ChatMessage(
      text: '''Hello! I'm WealthOrbit AI, your personal finance assistant. 🚀

I can help you with:
• **Financial Analysis** - Analyze your spending and investments
• **Budget Planning** - Create and optimize budgets
• **Goal Planning** - Calculate SIP needed for your goals
• **Investment Insights** - Get personalized investment advice
• **Tax Planning** - Understand tax implications

How can I help you today?''',
      isUser: false,
      timestamp: DateTime.now(),
    ));
  }
  
  Future<void> _sendMessage(String message) async {
    if (message.trim().isEmpty) return;
    
    setState(() {
      _messages.add(ChatMessage(
        text: message,
        isUser: true,
        timestamp: DateTime.now(),
      ));
      _isLoading = true;
    });
    
    _messageController.clear();
    _scrollToBottom();
    
    try {
      // Build context-aware prompt
      final prompt = '''You are WealthOrbit AI, a personal finance assistant for NRI individuals managing investments in UAE and India.

$_userContext

User Question: $message

Please provide helpful, actionable financial advice. Use the user's financial context when relevant. 
Format your response with markdown (bold, bullet points, etc.) for better readability.
Keep responses concise but comprehensive.''';
      
      // Call static method with two required parameters
      final response = await GeminiService.askQuestion(prompt, _userContext ?? '');
      
      setState(() {
        _messages.add(ChatMessage(
          text: response.isNotEmpty ? response : 'I apologize, but I couldn\'t process your request. Please try again.',
          isUser: false,
          timestamp: DateTime.now(),
        ));
        _isLoading = false;
      });
      
      _scrollToBottom();
    } catch (e) {
      setState(() {
        _messages.add(ChatMessage(
          text: 'Sorry, I encountered an error: ${e.toString()}. Please check your API key and try again.',
          isUser: false,
          timestamp: DateTime.now(),
          isError: true,
        ));
        _isLoading = false;
      });
    }
  }
  
  void _scrollToBottom() {
    Future.delayed(const Duration(milliseconds: 100), () {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }
  
  void _showQuickActions() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => _QuickActionsSheet(
        onActionSelected: (action) {
          Navigator.pop(context);
          _sendMessage(action);
        },
      ),
    );
  }
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: WoColors.bg,
      appBar: AppBar(
        backgroundColor: WoColors.bg,
        elevation: 0,
        title: Row(
          children: [
            WoIconBubble(Icons.auto_awesome, color: WoColors.indigo, size: 36),
            const SizedBox(width: 12),
            Text(
              'WealthOrbit AI',
              style: WoText.title(),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.refresh, color: WoColors.textMid),
            onPressed: () {
              setState(() {
                _messages.clear();
                _addWelcomeMessage();
              });
              _buildUserContext();
            },
            tooltip: 'New Chat',
          ),
        ],
      ),
      body: Column(
        children: [
          // Chat messages
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.all(16),
              itemCount: _messages.length + (_isLoading ? 1 : 0),
              itemBuilder: (context, index) {
                if (index == _messages.length && _isLoading) {
                  return const _TypingIndicator();
                }
                
                final message = _messages[index];
                return _MessageBubble(message: message)
                  .animate()
                  .fadeIn(duration: 300.ms)
                  .slideY(begin: 0.2, end: 0);
              },
            ),
          ),
          
          // Input area
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: WoColors.surface,
              border: Border(
                top: BorderSide(color: WoColors.borderHi),
              ),
            ),
            child: SafeArea(
              child: Row(
                children: [
                  // Quick actions button
                  IconButton(
                    icon: Icon(Icons.flash_on, color: WoColors.gold),
                    onPressed: _showQuickActions,
                    tooltip: 'Quick Actions',
                  ),

                  // Message input
                  Expanded(
                    child: Container(
                      decoration: woWell(radius: 24),
                      child: TextField(
                        controller: _messageController,
                        style: GoogleFonts.inter(color: WoColors.textHi),
                        decoration: InputDecoration(
                          hintText: 'Ask me anything about your finances...',
                          hintStyle: GoogleFonts.inter(color: WoColors.textLo),
                          border: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 12,
                          ),
                        ),
                        onSubmitted: _sendMessage,
                        textInputAction: TextInputAction.send,
                      ),
                    ),
                  ),

                  const SizedBox(width: 8),

                  // Send button
                  Container(
                    decoration: BoxDecoration(
                      color: WoColors.gold,
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: WoShadows.goldGlow,
                    ),
                    child: IconButton(
                      icon: const Icon(Icons.send, color: Colors.black),
                      onPressed: () => _sendMessage(_messageController.text),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
  
  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// CHAT MESSAGE MODEL
// ═══════════════════════════════════════════════════════════════════════════

class ChatMessage {
  final String text;
  final bool isUser;
  final DateTime timestamp;
  final bool isError;
  
  ChatMessage({
    required this.text,
    required this.isUser,
    required this.timestamp,
    this.isError = false,
  });
}

// ═══════════════════════════════════════════════════════════════════════════
// MESSAGE BUBBLE WIDGET
// ═══════════════════════════════════════════════════════════════════════════

class _MessageBubble extends StatelessWidget {
  final ChatMessage message;
  
  const _MessageBubble({required this.message});
  
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: message.isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          if (!message.isUser)
            Padding(
              padding: EdgeInsets.only(right: 12),
              child: WoIconBubble(Icons.auto_awesome, color: WoColors.indigo, size: 32),
            ),

          Flexible(
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: (message.isUser
                      ? woCard(tint: WoColors.gold)
                      : (message.isError ? woCard(tint: WoColors.red) : woCard()))
                  .copyWith(
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(18),
                  topRight: const Radius.circular(18),
                  bottomLeft: Radius.circular(message.isUser ? 18 : 4),
                  bottomRight: Radius.circular(message.isUser ? 4 : 18),
                ),
                border: message.isError
                    ? Border.all(color: WoColors.red.withValues(alpha: 0.5))
                    : null,
              ),
              child: _buildMessageContent(),
            ),
          ),

          if (message.isUser)
            Padding(
              padding: EdgeInsets.only(left: 12),
              child: WoIconBubble(Icons.person, color: WoColors.gold, size: 32),
            ),
        ],
      ),
    );
  }
  
  Widget _buildMessageContent() {
    // Simple markdown-like parsing for bold text and bullet points
    final lines = message.text.split('\n');
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: lines.map((line) {
        // Check for bold text (marked with **)
        if (line.contains('**')) {
          return _parseRichText(line);
        }
        
        // Check for bullet points
        if (line.startsWith('• ') || line.startsWith('- ')) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('• ', style: GoogleFonts.inter(color: WoColors.gold)),
                Expanded(
                  child: Text(
                    line.substring(2),
                    style: GoogleFonts.inter(
                      color: WoColors.textHi.withValues(alpha: 0.92),
                      fontSize: 14,
                      height: 1.5,
                    ),
                  ),
                ),
              ],
            ),
          );
        }

        return Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(
            line,
            style: GoogleFonts.inter(
              color: WoColors.textHi.withValues(alpha: 0.92),
              fontSize: 14,
              height: 1.5,
            ),
          ),
        );
      }).toList(),
    );
  }
  
  Widget _parseRichText(String text) {
    final spans = <TextSpan>[];
    final parts = text.split('**');
    
    for (int i = 0; i < parts.length; i++) {
      spans.add(TextSpan(
        text: parts[i],
        style: GoogleFonts.inter(
          color: WoColors.textHi.withValues(alpha: 0.92),
          fontSize: 14,
          height: 1.5,
          fontWeight: i.isOdd ? FontWeight.bold : FontWeight.normal,
        ),
      ));
    }
    
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: RichText(text: TextSpan(children: spans)),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// TYPING INDICATOR
// ═══════════════════════════════════════════════════════════════════════════

class _TypingIndicator extends StatelessWidget {
  const _TypingIndicator();
  
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        children: [
          WoIconBubble(Icons.auto_awesome, color: WoColors.indigo, size: 32),
          const SizedBox(width: 12),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: woCard(radius: 16),
            child: Row(
              children: [
                _AnimatedDot(delay: 0),
                const SizedBox(width: 4),
                _AnimatedDot(delay: 150),
                const SizedBox(width: 4),
                _AnimatedDot(delay: 300),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AnimatedDot extends StatefulWidget {
  final int delay;
  
  const _AnimatedDot({required this.delay});
  
  @override
  State<_AnimatedDot> createState() => _AnimatedDotState();
}

class _AnimatedDotState extends State<_AnimatedDot> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  
  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    
    Future.delayed(Duration(milliseconds: widget.delay), () {
      if (mounted) {
        _controller.repeat(reverse: true);
      }
    });
  }
  
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: Color.lerp(WoColors.textLo, WoColors.gold, _controller.value),
            shape: BoxShape.circle,
          ),
        );
      },
    );
  }
  
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// QUICK ACTIONS SHEET
// ═══════════════════════════════════════════════════════════════════════════

class _QuickActionsSheet extends StatelessWidget {
  final Function(String) onActionSelected;
  
  const _QuickActionsSheet({required this.onActionSelected});
  
  @override
  Widget build(BuildContext context) {
    final actions = [
      ('📊', 'Analyze my spending', 'Analyze my spending patterns and suggest ways to save money'),
      ('🎯', 'Calculate SIP for goal', 'How much SIP do I need for a goal of AED 500,000 in 10 years?'),
      ('💰', 'Investment advice', 'Based on my financial situation, what investments should I consider?'),
      ('🏠', 'Real estate analysis', 'Is my real estate portfolio well-diversified?'),
      ('📈', 'Portfolio review', 'Review my investment portfolio and suggest improvements'),
      ('🛡️', 'Risk assessment', 'Assess my overall financial risk exposure'),
      ('💳', 'Debt strategy', 'What\'s the best strategy to pay off my debts?'),
      ('🎓', 'Children education', 'How should I plan for my children\'s education?'),
    ];
    
    return WoSheet(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Quick Actions',
            style: WoText.display(),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: actions.map((action) {
              return InkWell(
                onTap: () => onActionSelected(action.$3),
                borderRadius: BorderRadius.circular(WoRadius.control),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: woWell(),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(action.$1, style: const TextStyle(fontSize: 18)),
                      const SizedBox(width: 8),
                      Text(
                        action.$2,
                        style: WoText.bodyHi(),
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}
