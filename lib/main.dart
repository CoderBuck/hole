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
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with SingleTickerProviderStateMixin {
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

class _SendPageState extends State<SendPage> {
  String? _selectedPath;
  String? _fileName;
  String? _status;
  String? _ticket;
  bool _isSharing = false;

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
          dataDir: appDir.path
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

class _ReceivePageState extends State<ReceivePage> {
  final _controller = TextEditingController();
  String? _status;
  List<ReceivedFile> _receivedFiles = [];
  bool _isDownloading = false;

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
        dataDir: appDir.path,
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

  @override
  Widget build(BuildContext context) {
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
                        leading: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: colorScheme.primaryContainer,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(Icons.insert_drive_file_rounded, color: colorScheme.onPrimaryContainer),
                        ),
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