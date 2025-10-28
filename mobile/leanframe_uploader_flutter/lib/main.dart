import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:file_picker/file_picker.dart';

void main() => runApp(const LeanFrameApp());

/// ----------------------------------------------------------------------------
/// App State & API
/// ----------------------------------------------------------------------------
class AppState extends ChangeNotifier {
  String frameName = "My Frame";
  String? serverBase; // e.g. http://192.168.1.50:8765
  String authToken = "change-me";
  bool connected = false;

  final List<MediaItem> media = [];

  int get imageCount => media.length;

  void setServer({required String base, required String token}) {
    serverBase = base.trim();
    authToken = token.trim();
    notifyListeners();
  }

  void setFrameName(String name) {
    frameName = name.trim().isEmpty ? frameName : name.trim();
    notifyListeners();
  }

  void setConnection(bool ok) {
    connected = ok;
    notifyListeners();
  }

  void addMedia(MediaItem item) {
    media.add(item);
    notifyListeners();
  }
}

class MediaItem {
  final String id;
  final String thumbPath; // placeholder for now
  MediaItem({required this.id, required this.thumbPath});
}

class Api {
  final String base;
  final String token;
  Api(this.base, this.token);

  Map<String, String> get _headers => {'X-Auth-Token': token};

  Future<bool> ping() async {
    try {
      final res = await http
          .get(Uri.parse(base), headers: _headers)
          .timeout(const Duration(seconds: 2));
      return res.statusCode < 500; // 404 on / is fine
    } catch (_) {
      return false;
    }
  }

  Future<bool> uploadFile(File file) async {
    try {
      final req = http.MultipartRequest('POST', Uri.parse("$base/upload"));
      req.headers.addAll(_headers);
      req.files.add(await http.MultipartFile.fromPath('file', file.path));
      final streamed = await req.send();
      return streamed.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}

/// ----------------------------------------------------------------------------
/// App root
/// ----------------------------------------------------------------------------
class LeanFrameApp extends StatelessWidget {
  const LeanFrameApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LeanFrame',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.amber, useMaterial3: true),
      home: InheritedAppState(
        notifier: AppState(),
        child: const HomeScreen(),
      ),
    );
  }
}

class InheritedAppState extends InheritedNotifier<AppState> {
  const InheritedAppState({super.key, required super.notifier, required super.child});
  static AppState of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<InheritedAppState>()!.notifier!;
}

/// ----------------------------------------------------------------------------
/// Home (system picker only)
/// ----------------------------------------------------------------------------
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

enum HubTab { activity, photos }

class _HomeScreenState extends State<HomeScreen> {
  HubTab tab = HubTab.photos;

  @override
  Widget build(BuildContext context) {
    final state = InheritedAppState.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(child: Text(state.frameName, overflow: TextOverflow.ellipsis)),
            const SizedBox(width: 8),
            InkWell(
              onTap: () async {
                final newName = await _promptForText(context, "Rename frame", state.frameName);
                if (newName != null) state.setFrameName(newName);
              },
              child: const Icon(Icons.edit, size: 18),
            ),
          ],
        ),
        centerTitle: true,
        actions: [
          Icon(
            state.connected ? Icons.circle : Icons.circle_outlined,
            color: state.connected ? Colors.green : Colors.grey,
            size: 12,
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () async {
              final out = await showDialog<_ServerCfg>(
                context: context,
                builder: (_) => _ServerConfigDialog(
                  initialBase: state.serverBase ?? "http://192.168.1.100:8765",
                  initialToken: state.authToken,
                ),
              );
              if (out != null) {
                state.setServer(base: out.base, token: out.token);
                final up = await Api(out.base, out.token).ping();
                state.setConnection(up);
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(up ? "Connected" : "Server not reachable")),
                );
              }
            },
          ),
        ],
      ),

      body: Column(
        children: [
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: CupertinoSegmentedControl<HubTab>(
              groupValue: tab,
              onValueChanged: (v) => setState(() => tab = v),
              children: const {
                HubTab.activity: Padding(padding: EdgeInsets.all(8), child: Text("Activity")),
                HubTab.photos: Padding(
                  padding: EdgeInsets.all(8),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.grid_on, size: 16), SizedBox(width: 6), Text("Photos")
                  ]),
                ),
              },
            ),
          ),
          const SizedBox(height: 8),
          if (tab == HubTab.photos)
            _PhotosHeaderRow(count: state.imageCount)
          else
            const _ActivityPlaceholder(),
          const Divider(height: 1),
          Expanded(
            child: tab == HubTab.photos ? const _PhotoGrid() : const _ActivityCenter(),
          ),
        ],
      ),

      // System picker + upload
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: Colors.amber,
        foregroundColor: Colors.black,
        icon: const Icon(Icons.add),
        label: const Text("Add Photos"),
        onPressed: () async => _runSystemPickerFlow(context),
      ),
    );
  }

  /// -------------------- System picker flow -----------------------
  Future<void> _runSystemPickerFlow(BuildContext context) async {
    final state = InheritedAppState.of(context);
    if (state.serverBase == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Open settings (gear) and set Server URL/Token first.")),
      );
      return;
    }
    final api = Api(state.serverBase!, state.authToken);

    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.image, // or FileType.media for images+videos
    );
    if (result == null || result.files.isEmpty) return;

    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (_) => _ConfirmUploadSheet(count: result.files.length),
    );
    if (confirmed != true) return;

    int ok = 0, fail = 0;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text("Uploading ${result.files.length} file(s)…")),
    );

    for (final f in result.files) {
      final path = f.path;
      if (path == null) continue;
      final success = await api.uploadFile(File(path));
      if (success) {
        ok++;
        InheritedAppState.of(context).addMedia(MediaItem(id: path, thumbPath: path));
      } else {
        fail++;
      }
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text("Uploaded $ok file(s)${fail > 0 ? ", $fail failed" : ""}")),
    );
  }
}

/// Header row on Photos tab
class _PhotosHeaderRow extends StatelessWidget {
  final int count;
  const _PhotosHeaderRow({required this.count});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Row(
        children: [
          Text("Photos ($count)", style: const TextStyle(fontWeight: FontWeight.w600)),
          const Spacer(),
          OutlinedButton.icon(
            onPressed: () {
              Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SelectionEditor()));
            },
            icon: const Icon(Icons.check_box),
            label: const Text("Select"),
          ),
        ],
      ),
    );
  }
}

class _ActivityPlaceholder extends StatelessWidget {
  const _ActivityPlaceholder();
  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.fromLTRB(12, 12, 12, 8),
      child: Align(alignment: Alignment.centerLeft, child: Text("Activity")),
    );
  }
}

class _ActivityCenter extends StatelessWidget {
  const _ActivityCenter();
  @override
  Widget build(BuildContext context) {
    return const Center(child: Text("Recent uploads & sync events will appear here."));
  }
}

class _PhotoGrid extends StatelessWidget {
  const _PhotoGrid();
  @override
  Widget build(BuildContext context) {
    final state = InheritedAppState.of(context);
    if (state.media.isEmpty) {
      return const Center(child: Text("No photos yet — tap Add Photos to begin."));
    }
    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3, mainAxisSpacing: 6, crossAxisSpacing: 6),
      itemCount: state.media.length,
      itemBuilder: (_, i) {
        final m = state.media[i];
        return Container(
          color: Colors.grey.shade300,
          child: const Center(child: Icon(Icons.photo, size: 36, color: Colors.white70)),
        );
      },
    );
  }
}

/// ----------------------------------------------------------------------------
/// Selection editor (for already-uploaded grid items; optional stub)
/// ----------------------------------------------------------------------------
class SelectionEditor extends StatefulWidget {
  const SelectionEditor({super.key});
  @override
  State<SelectionEditor> createState() => _SelectionEditorState();
}

class _SelectionEditorState extends State<SelectionEditor> {
  final Set<String> selected = {};
  @override
  Widget build(BuildContext context) {
    final state = InheritedAppState.of(context);
    final items = state.media;

    return Scaffold(
      appBar: AppBar(
        leading: TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
        title: Text("${selected.length} selected"),
        actions: [
          TextButton(
            onPressed: selected.isEmpty ? null : () async {
              await showModalBottomSheet(
                context: context,
                showDragHandle: true,
                builder: (_) => const _SelectionActionsSheet(),
              );
              if (mounted) Navigator.pop(context);
            },
            child: Text("Next", style: TextStyle(color: selected.isEmpty ? Colors.grey : Colors.blue)),
          ),
        ],
      ),
      body: GridView.builder(
        padding: const EdgeInsets.all(8),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, mainAxisSpacing: 6, crossAxisSpacing: 6),
        itemCount: items.length,
        itemBuilder: (_, i) {
          final m = items[i];
          final isSel = selected.contains(m.id);
          return GestureDetector(
            onTap: () {
              setState(() { isSel ? selected.remove(m.id) : selected.add(m.id); });
            },
            child: Stack(
              fit: StackFit.expand,
              children: [
                Container(color: Colors.grey.shade300, child: const Center(child: Icon(Icons.photo, color: Colors.white70))),
                if (isSel)
                  Container(
                    color: Colors.black26,
                    alignment: Alignment.topRight,
                    padding: const EdgeInsets.all(6),
                    child: const Icon(Icons.check_circle, color: Colors.lightBlueAccent),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _SelectionActionsSheet extends StatelessWidget {
  const _SelectionActionsSheet();
  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: const [
        ListTile(leading: Icon(Icons.slideshow), title: Text("Include in slideshow")),
        ListTile(leading: Icon(Icons.block), title: Text("Exclude from slideshow")),
        ListTile(leading: Icon(Icons.delete_outline), title: Text("Remove from frame")),
        SizedBox(height: 8),
      ]),
    );
  }
}

/// ----------------------------------------------------------------------------
/// Small UI helpers
/// ----------------------------------------------------------------------------
class _ConfirmUploadSheet extends StatelessWidget {
  final int count;
  const _ConfirmUploadSheet({required this.count});
  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text("Ready to upload", style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text("$count file(s) selected"),
          const SizedBox(height: 16),
          Row(
            children: [
              OutlinedButton.icon(onPressed: () => Navigator.pop(context, false), icon: const Icon(Icons.close), label: const Text("Cancel")),
              const Spacer(),
              FilledButton.icon(onPressed: () => Navigator.pop(context, true), icon: const Icon(Icons.cloud_upload), label: const Text("Upload")),
            ],
          ),
        ]),
      ),
    );
  }
}

class _ServerCfg { final String base, token; _ServerCfg(this.base, this.token); }

class _ServerConfigDialog extends StatefulWidget {
  final String initialBase, initialToken;
  const _ServerConfigDialog({required this.initialBase, required this.initialToken});
  @override
  State<_ServerConfigDialog> createState() => _ServerConfigDialogState();
}
class _ServerConfigDialogState extends State<_ServerConfigDialog> {
  late final TextEditingController _base = TextEditingController(text: widget.initialBase);
  late final TextEditingController _token = TextEditingController(text: widget.initialToken);
  @override
  void dispose() { _base.dispose(); _token.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text("Server settings"),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: _base, decoration: const InputDecoration(labelText: "Server URL (http://ip:8765)")),
        const SizedBox(height: 8),
        TextField(controller: _token, decoration: const InputDecoration(labelText: "Auth token")),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
        FilledButton(onPressed: () => Navigator.pop(context, _ServerCfg(_base.text.trim(), _token.text.trim())), child: const Text("Save")),
      ],
    );
  }
}

Future<String?> _promptForText(BuildContext context, String title, String initial) async {
  final ctrl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (_) => AlertDialog(
      title: Text(title),
      content: TextField(controller: ctrl, autofocus: true),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
        FilledButton(onPressed: () => Navigator.pop(context, ctrl.text), child: const Text("Save")),
      ],
    ),
  );
}
