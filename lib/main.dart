import 'package:flutter/material.dart';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:share_plus/share_plus.dart';
import 'package:flutter/services.dart'; 
import 'package:hole/src/rust/api.dart'; 
import 'package:hole/src/rust/frb_generated.dart'; 

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  final appDir = await getApplicationDocumentsDirectory();
  final nodeId = await initNode(dataDir: appDir.path);
  debugPrint("Node initialized with ID: $nodeId");
  runApp(const HoleApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) => const HoleApp();
}

class HoleApp extends StatelessWidget {
  const HoleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Hole',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
          brightness: Brightness.light,
        ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
          brightness: Brightness.dark,
        ),
      ),
      home: const MainScreen(),
    );
  }
}

class Message {
  final String text;
  final bool isMe;
  final DateTime time;

  Message({required this.text, required this.isMe, required this.time});
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _currentIndex = 0;
  final Map<String, List<Message>> _allMessages = {};
  final List<Friend> _friends = [];

  @override
  void initState() {
    super.initState();
    _initMessageSubscription();
  }

  void _initMessageSubscription() {
    subscribeMessages().listen((msg) {
      debugPrint("DEBUG: [Receiver] Got message from ${msg.from}: ${msg.text}");
      setState(() {
        // Find existing friend or create new one with the ticket provided in message
        int friendIndex = _friends.indexWhere((f) => f.nodeId == msg.from);
        if (friendIndex == -1) {
          _friends.add(Friend(
            nodeId: msg.from,
            addr: msg.ticket, // Use the full ticket from the message!
            alias: "Friend ${msg.from.substring(0, 4)}",
          ));
        } else {
          // Update ticket if it changed or was incomplete
          _friends[friendIndex] = Friend(
            nodeId: msg.from,
            addr: msg.ticket,
            alias: _friends[friendIndex].alias,
          );
        }

        final list = _allMessages[msg.from] ?? [];
        list.add(Message(text: msg.text, isMe: false, time: DateTime.now()));
        _allMessages[msg.from] = list;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: [
          ChatListScreen(
            friends: _friends,
            messages: _allMessages,
            onAddFriend: (f) => setState(() => _friends.add(f)),
          ),
          const TransferScreen(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (index) {
          setState(() {
            _currentIndex = index;
          });
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline_rounded),
            selectedIcon: Icon(Icons.chat_bubble_rounded),
            label: 'Chats',
          ),
          NavigationDestination(
            icon: Icon(Icons.swap_horiz_rounded),
            selectedIcon: Icon(Icons.swap_horizontal_circle_rounded),
            label: 'Transfer',
          ),
        ],
      ),
    );
  }
}

class Friend {
  final String nodeId;
  final String addr;
  final String alias;

  Friend({required this.nodeId, required this.addr, required this.alias});
}

class ChatListScreen extends StatefulWidget {
  final List<Friend> friends;
  final Map<String, List<Message>> messages;
  final Function(Friend) onAddFriend;

  const ChatListScreen({
    super.key,
    required this.friends,
    required this.messages,
    required this.onAddFriend,
  });

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> {
  Future<void> _showMyQRCode() async {
    debugPrint("DEBUG: _showMyQRCode clicked");
    
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator()),
    );

    try {
      debugPrint("DEBUG: Fetching my address from Rust...");
      final addr = await getMyAddr();
      debugPrint("DEBUG: Got address (length: ${addr.length}): $addr");
      
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();

      showDialog(
        context: context,
        useRootNavigator: true,
        builder: (context) {
          return AlertDialog(
            title: const Text("My Card"),
            content: SizedBox(
              width: double.maxFinite,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text("Scan to add me as a friend"),
                  const SizedBox(height: 20),
                  Container(
                    width: 220,
                    height: 220,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.1),
                          blurRadius: 10,
                        )
                      ],
                    ),
                    child: QrImageView(
                      data: addr,
                      version: QrVersions.auto,
                      size: 200.0,
                      errorStateBuilder: (cxt, err) {
                        return Center(child: Text("QR Error: $err", style: const TextStyle(color: Colors.red)));
                      },
                    ),
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    "Your Node ID / Ticket:",
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceVariant,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: SelectableText(
                      addr,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 9, fontFamily: 'monospace'),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: addr));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Address copied to clipboard')),
                  );
                },
                child: const Text("Copy"),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text("Close"),
              ),
            ],
          );
        },
      );
    } catch (e) {
      debugPrint("DEBUG: Error in _showMyQRCode: $e");
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  Future<void> _scanToAddFriend() async {
    var status = await Permission.camera.request();
    if (status.isGranted) {
      if (!mounted) return;
      final String? code = await Navigator.push(
        context,
        MaterialPageRoute(builder: (context) => const QRScannerScreen()),
      );

      if (code != null) {
        _addFriend(code);
      }
    } else {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Camera permission required')),
      );
    }
  }

  void _addFriend(String ticket) async {
    if (ticket.isEmpty) return;
    
    // Aggressive cleaning
    ticket = ticket.trim().replaceAll(RegExp(r'[\r\n\t]'), '');
    if (ticket.startsWith('TICKET:')) {
      ticket = ticket.substring(7);
    }
    
    // Parse NodeID for local display
    final nodeId = ticket.length > 64 ? ticket.substring(0, 10) : ticket; // Simplified
    
    final newFriend = Friend(
      nodeId: nodeId,
      addr: ticket, // Now ticket is cleaned
      alias: "Friend ${nodeId.substring(0, nodeId.length > 6 ? 6 : nodeId.length)}",
    );

    if (!widget.friends.any((f) => f.addr == ticket)) {
      widget.onAddFriend(newFriend);
      
      // AUTO HANDSHAKE: Send a message to let them know who we are
      try {
        final myTicket = await getMyAddr();
        debugPrint("DEBUG: [Handshake] Cleaned TargetTicket len=${ticket.length}, MyTicket len=${myTicket.length}");
        await sendText(targetTicket: ticket, my_ticket: myTicket, text: "Hey! I added you.");
      } catch (e) {
        debugPrint("Handshake failed: $e");
      }
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Friend added!')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Hole Chat',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            onPressed: _showMyQRCode,
            icon: const Icon(Icons.qr_code_rounded),
            tooltip: "My QR Code",
          ),
          IconButton(
            onPressed: _scanToAddFriend,
            icon: const Icon(Icons.person_add_rounded),
            tooltip: "Add Friend",
          ),
        ],
      ),
      body: widget.friends.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.chat_bubble_outline_rounded,
                      size: 64, color: colorScheme.outlineVariant),
                  const SizedBox(height: 16),
                  const Text("No friends yet"),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed: _scanToAddFriend,
                    icon: const Icon(Icons.qr_code_scanner_rounded),
                    label: const Text("Add Friend"),
                  ),
                ],
              ),
            )
          : ListView.builder(
              itemCount: widget.friends.length,
              itemBuilder: (ctx, i) {
                final friend = widget.friends[i];
                final lastMsg = widget.messages[friend.nodeId]?.last;
                return ListTile(
                  leading: CircleAvatar(
                    backgroundColor: colorScheme.primaryContainer,
                    child: Text(friend.alias[0]),
                  ),
                  title: Text(friend.alias),
                  subtitle: Text(
                    lastMsg?.text ?? friend.nodeId,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12),
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => ChatScreen(
                          friend: friend,
                          messages: widget.messages[friend.nodeId] ?? [],
                        ),
                      ),
                    ).then((_) => setState(() {}));
                  },
                );
              },
            ),
    );
  }
}

class ChatScreen extends StatefulWidget {
  final Friend friend;
  final List<Message> messages;

  const ChatScreen({super.key, required this.friend, required this.messages});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  void _sendMessage() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;

    _controller.clear();
    setState(() {
      widget.messages.add(Message(text: text, isMe: true, time: DateTime.now()));
    });
    
    _scrollToBottom();

    try {
      final myTicket = await getMyAddr();
      debugPrint("DEBUG: [Chat] TargetTicket len=${widget.friend.addr.length}, MyTicket len=${myTicket.length}, Text len=${text.length}");
      await sendText(targetTicket: widget.friend.addr, myTicket: myTicket, text: text);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Send failed: $e')),
      );
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.friend.alias),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.all(16),
              itemCount: widget.messages.length,
              itemBuilder: (ctx, i) {
                final msg = widget.messages[i];
                return Align(
                  alignment: msg.isMe ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(
                      color: msg.isMe ? colorScheme.primary : colorScheme.surfaceVariant,
                      borderRadius: BorderRadius.circular(20).copyWith(
                        bottomRight: msg.isMe ? const Radius.circular(0) : null,
                        bottomLeft: !msg.isMe ? const Radius.circular(0) : null,
                      ),
                    ),
                    child: Text(
                      msg.text,
                      style: TextStyle(
                        color: msg.isMe ? colorScheme.onPrimary : colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: colorScheme.surface,
              border: Border(top: BorderSide(color: colorScheme.outlineVariant)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    decoration: const InputDecoration(
                      hintText: 'Type a message...',
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.symmetric(horizontal: 16),
                    ),
                    onSubmitted: (_) => _sendMessage(),
                  ),
                ),
                IconButton(
                  onPressed: _sendMessage,
                  icon: const Icon(Icons.send_rounded),
                  color: colorScheme.primary,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class TransferScreen extends StatefulWidget {
  const TransferScreen({super.key});

  @override
  State<TransferScreen> createState() => _TransferScreenState();
}

class _TransferScreenState extends State<TransferScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Hole',
          style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.2),
        ),
        centerTitle: true,
        elevation: 0,
        backgroundColor: colorScheme.surface,
        bottom: TabBar(
          controller: _tabController,
          indicatorSize: TabBarIndicatorSize.label,
          indicatorWeight: 3,
          labelStyle: const TextStyle(fontWeight: FontWeight.bold),
          tabs: const [
            Tab(icon: Icon(Icons.send_rounded), text: 'Send'),
            Tab(icon: Icon(Icons.download_for_offline_rounded), text: 'Receive'),
          ],
        ),
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              colorScheme.surface,
              colorScheme.surfaceVariant.withOpacity(0.3),
            ],
          ),
        ),
        child: TabBarView(
          controller: _tabController,
          children: const [
            SendPage(),
            ReceivePage(),
          ],
        ),
      ),
    );
  }
}

// --- Send Page ---

class SendPage extends StatefulWidget {
  const SendPage({super.key});

  @override
  State<SendPage> createState() => _SendPageState();
}

class _SendPageState extends State<SendPage> with AutomaticKeepAliveClientMixin {
  String? _selectedPath;
  String? _fileName;
  String? _status;
  String? _ticket;
  bool _isSharing = false;

  @override
  bool get wantKeepAlive => true;

  Future<void> _pickAndShare() async {
    if (_isSharing) return;

    FilePickerResult? result = await FilePicker.platform.pickFiles();
    if (result != null && result.files.single.path != null) {
      setState(() {
        _selectedPath = result.files.single.path;
        _fileName = result.files.single.name;
        _status = "Initializing...";
        _ticket = null;
        _isSharing = true;
      });

      final appDir = await getApplicationDocumentsDirectory();
      
      try {
        final stream = startSend(
          filePath: _selectedPath!, 
        );
        
        await for (final msg in stream) {
          if (msg.startsWith("TICKET:")) {
            setState(() {
              _ticket = msg.substring(7);
            });
          }
          setState(() {
            _status = msg;
          });
        }
      } catch (e) {
        setState(() {
          _status = "Error: $e";
          _isSharing = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final colorScheme = Theme.of(context).colorScheme;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // File Picker Area
          GestureDetector(
            onTap: _isSharing ? null : _pickAndShare,
            child: Container(
              height: 180,
              decoration: BoxDecoration(
                color: _isSharing ? colorScheme.surface : colorScheme.primaryContainer.withOpacity(0.4),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                  color: colorScheme.primary.withOpacity(0.2),
                  width: 2,
                  style: BorderStyle.solid,
                ),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    _selectedPath == null ? Icons.add_circle_outline_rounded : Icons.insert_drive_file_rounded,
                    size: 48,
                    color: colorScheme.primary,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    _fileName ?? "Select a file to share",
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 32),

          if (_ticket != null) ...[
            Card(
              elevation: 0,
              color: colorScheme.secondaryContainer.withOpacity(0.5),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              child: Padding(
                padding: const EdgeInsets.all(20.0),
                child: Column(
                  children: [
                    const Text(
                      "Scan to receive",
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: QrImageView(
                        data: _ticket!,
                        version: QrVersions.auto,
                        size: 180.0,
                      ),
                    ),
                    const SizedBox(height: 16),
                    OutlinedButton.icon(
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: _ticket!));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Ticket copied to clipboard')),
                        );
                      },
                      icon: const Icon(Icons.copy_rounded, size: 18),
                      label: const Text("Copy Ticket String"),
                    ),
                  ],
                ),
              ),
            ),
          ],

          if (_status != null) ...[
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: colorScheme.surfaceVariant.withOpacity(0.5),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: colorScheme.primary,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _status!,
                      style: TextStyle(fontSize: 13, color: colorScheme.onSurfaceVariant),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// --- Receive Page ---

class ReceivedFile {
  final String name;
  final String path;
  final DateTime time;

  ReceivedFile({required this.name, required this.path, required this.time});
}

class ReceivePage extends StatefulWidget {
  const ReceivePage({super.key});

  @override
  State<ReceivePage> createState() => _ReceivePageState();
}

class _ReceivePageState extends State<ReceivePage> with AutomaticKeepAliveClientMixin {
  final _controller = TextEditingController();
  String? _status;
  List<ReceivedFile> _receivedFiles = [];
  bool _isDownloading = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadRecentDownloads();
  }

  Future<void> _loadRecentDownloads() async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final downloadDir = Directory('${appDir.path}/downloads');
      if (await downloadDir.exists()) {
        final List<FileSystemEntity> entities = await downloadDir.list().toList();
        final List<ReceivedFile> files = [];
        for (final entity in entities) {
          if (entity is File) {
            final stat = await entity.stat();
            files.add(ReceivedFile(
              name: entity.path.split('/').last,
              path: entity.path,
              time: stat.modified,
            ));
          }
        }
        // Sort by time, newest first
        files.sort((a, b) => b.time.compareTo(a.time));
        
        if (mounted) {
          setState(() {
            _receivedFiles = files;
          });
        }
      }
    } catch (e) {
      debugPrint("Error loading recent downloads: $e");
    }
  }

  Future<void> _startDownload() async {
    final ticket = _controller.text.trim();
    if (ticket.isEmpty || _isDownloading) return;

    setState(() {
      _isDownloading = true;
      _status = "Starting download...";
    });

    try {
      final appDir = await getApplicationDocumentsDirectory();
      final downloadDir = Directory('${appDir.path}/downloads');
      if (!await downloadDir.exists()) {
        await downloadDir.create(recursive: true);
      }
      
      final stream = receiveFile(
        ticketStr: ticket,
        downloadDir: downloadDir.path
      );

      String? lastSavedPath;
      await for (final msg in stream) {
        setState(() {
          _status = msg;
        });
        if (msg.startsWith("Path: ")) {
          lastSavedPath = msg.substring(6);
        }
      }

      if (lastSavedPath != null) {
        final file = File(lastSavedPath);
        setState(() {
          _receivedFiles.insert(0, ReceivedFile(
            name: file.path.split('/').last,
            path: file.path,
            time: DateTime.now(),
          ));
          _status = "Download successful!";
        });
      }
    } catch (e) {
      setState(() {
        _status = "Error: $e";
      });
    } finally {
      setState(() {
        _isDownloading = false;
      });
    }
  }

  Widget _buildFileThumbnail(String path, ColorScheme colorScheme) {
    final extension = path.split('.').last.toLowerCase();
    final isImage = ['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp'].contains(extension);
    
    if (isImage) {
      return Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: colorScheme.surfaceVariant,
          border: Border.all(color: colorScheme.outlineVariant.withOpacity(0.5)),
          image: DecorationImage(
            image: FileImage(File(path)),
            fit: BoxFit.cover,
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(Icons.insert_drive_file_rounded, color: colorScheme.onPrimaryContainer),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.all(20.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Input Card
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: BorderSide(color: colorScheme.outlineVariant),
            ),
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: Row(
                children: [
                  const SizedBox(width: 12),
                  const Icon(Icons.vpn_key_rounded, color: Colors.grey),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      decoration: const InputDecoration(
                        hintText: 'Enter or scan ticket',
                        border: InputBorder.none,
                      ),
                    ),
                  ),
                  IconButton.filledTonal(
                    icon: const Icon(Icons.qr_code_scanner_rounded),
                    onPressed: _scanQRCode,
                    tooltip: 'Scan QR Code',
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _isDownloading ? null : _startDownload,
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            ),
            icon: _isDownloading 
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.download_for_offline_rounded),
            label: Text(_isDownloading ? 'Downloading...' : 'Start Download'),
          ),
          
          if (_status != null) ...[
            const SizedBox(height: 12),
            Text(
              _status!,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: colorScheme.primary),
            ),
          ],

          const SizedBox(height: 32),
          Row(
            children: [
              Text(
                "Recent Downloads",
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: colorScheme.onSurface),
              ),
              const Spacer(),
              if (_receivedFiles.isNotEmpty)
                TextButton(
                  onPressed: () => setState(() => _receivedFiles.clear()),
                  child: const Text("Clear"),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: _receivedFiles.isEmpty 
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.folder_open_rounded, size: 64, color: colorScheme.outlineVariant),
                      const SizedBox(height: 16),
                      Text("No files received yet", style: TextStyle(color: colorScheme.outline)),
                    ],
                  ),
                )
              : ListView.separated(
                  itemCount: _receivedFiles.length,
                  separatorBuilder: (context, index) => const SizedBox(height: 8),
                  itemBuilder: (ctx, i) {
                    final file = _receivedFiles[i];
                    return Card(
                      elevation: 0,
                      color: colorScheme.surfaceVariant.withOpacity(0.3),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                        side: BorderSide(color: colorScheme.outlineVariant.withOpacity(0.5)),
                      ),
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                        leading: _buildFileThumbnail(file.path, colorScheme),
                        title: Text(
                          file.name,
                          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          "${file.time.hour.toString().padLeft(2,'0')}:${file.time.minute.toString().padLeft(2,'0')}",
                          style: TextStyle(fontSize: 12, color: colorScheme.outline),
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.share_rounded),
                          onPressed: () => Share.shareXFiles([XFile(file.path)]),
                          tooltip: 'Share / Export',
                        ),
                      ),
                    );
                  },
                ),
          ),
        ],
      ),
    );
  }

  Future<void> _scanQRCode() async {
    var status = await Permission.camera.request();
    if (status.isGranted) {
      if (!mounted) return;
      final String? code = await Navigator.push(
        context,
        MaterialPageRoute(builder: (context) => const QRScannerScreen()),
      );

      if (code != null) {
        setState(() {
          _controller.text = code;
        });
      }
    } else {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Camera permission required')),
      );
    }
  }
}

class QRScannerScreen extends StatefulWidget {
  const QRScannerScreen({super.key});

  @override
  State<QRScannerScreen> createState() => _QRScannerScreenState();
}

class _QRScannerScreenState extends State<QRScannerScreen> {
  bool _hasScanned = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan QR Code'),
        centerTitle: true,
      ),
      body: Stack(
        children: [
          MobileScanner(
            onDetect: (capture) {
              if (_hasScanned) return;
              final List<Barcode> barcodes = capture.barcodes;
              for (final barcode in barcodes) {
                if (barcode.rawValue != null) {
                  _hasScanned = true;
                  Navigator.pop(context, barcode.rawValue);
                  break;
                }
              }
            },
          ),
          // Scanner Overlay
          Center(
            child: Container(
              width: 250,
              height: 250,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white, width: 2),
                borderRadius: BorderRadius.circular(24),
              ),
            ),
          ),
        ],
      ),
    );
  }
}