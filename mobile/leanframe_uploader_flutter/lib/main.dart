import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:file_picker/file_picker.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

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

class RuntimeConfig {
  // Render
  String mode;           // "cover" | "contain"
  String paddingStyle;   // "blur" | "solid"
  String paddingColor;   // "#RRGGBB"
  double blurAmount;     // e.g., 16.0 (used when style == "blur")

  // Playback
  double slideDurationS; // better name for default_image_seconds
  bool shuffle;
  bool loop;
  int crossfadeMs;       // better name for transition_crossfade_ms

  RuntimeConfig({
    required this.mode,
    required this.paddingStyle,
    required this.paddingColor,
    required this.blurAmount,
    required this.slideDurationS,
    required this.shuffle,
    required this.loop,
    required this.crossfadeMs,
  });

  factory RuntimeConfig.fromJson(Map<String,dynamic> j) => RuntimeConfig(
    mode: j["render"]["mode"],
    paddingStyle: j["render"]["padding"]["style"],
    paddingColor: j["render"]["padding"]["color"],
    blurAmount: (j["render"]["padding"]["blur_amount"] ?? 16).toDouble(),
    slideDurationS: (j["playback"]["slide_duration_s"]).toDouble(),
    shuffle: j["playback"]["shuffle"] == true,
    loop: j["playback"]["loop"] == true,
    crossfadeMs: j["playback"]["crossfade_ms"],
  );

  Map<String,dynamic> toJson() => {
    "render": {
      "mode": mode,
      "padding": {
        "style": paddingStyle,
        "color": paddingColor,
        "blur_amount": blurAmount,
      }
    },
    "playback": {
      "slide_duration_s": slideDurationS,
      "shuffle": shuffle,
      "loop": loop,
      "crossfade_ms": crossfadeMs,
    }
  };
}

extension ApiRuntime on Api {
  Future<RuntimeConfig> getRuntime() async {
    final res = await http.get(Uri.parse("$base/config/runtime"), headers: _headers);
    if (res.statusCode != 200) { throw Exception("get runtime ${res.statusCode}"); }
    return RuntimeConfig.fromJson(json.decode(res.body));
  }
  Future<bool> putRuntime(RuntimeConfig cfg) async {
    final res = await http.put(
      Uri.parse("$base/config/runtime"),
      headers: {..._headers, "Content-Type": "application/json"},
      body: json.encode(cfg.toJson()),
    );
    return res.statusCode == 200;
  }
}

/// ----------------------------------------------------------------------------
/// First-run wizard
/// ----------------------------------------------------------------------------
class FirstRunWizard extends StatefulWidget {
  const FirstRunWizard({super.key});
  @override
  State<FirstRunWizard> createState() => _FirstRunWizardState();
}

class _FirstRunWizardState extends State<FirstRunWizard> {
  int step = 0;
  PairPayload? payload;
  final ssidCtrl = TextEditingController();
  final passCtrl = TextEditingController();
  bool posting = false;
  bool _handledScan = false; 
  String? error;

  @override
  void dispose() { ssidCtrl.dispose(); passCtrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final steps = [
      _stepWelcome(),
      _stepScanQR(),
      _stepConnectAP(),
      _stepEnterHomeWifi(),
      _stepDone(),
    ];
    return Scaffold(
      appBar: AppBar(title: const Text("Set up your frame")),
      body: steps[step],
    );
  }

  Widget _stepWelcome() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text("Welcome", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        const Text("Plug in your LeanFrame. When the QR appears, continue."),
        const Spacer(),
        Row(children: [
          const Spacer(),
          FilledButton(onPressed: () => setState(() => step = 1), child: const Text("Continue")),
        ]),
      ]),
    );
  }

  Widget _stepScanQR() {
    return Column(children: [
      const SizedBox(height: 8),
      const Text("Scan the QR on your frame"),
      const SizedBox(height: 12),
      Expanded(
        child: MobileScanner(
          onDetect: (capture) {
            if (_handledScan) return; // throttle multiple callbacks
            final b = capture.barcodes.firstOrNull;
            final raw = b?.rawValue;
            if (raw == null || raw.isEmpty) {
              // Ignore frames with no string payload
              return;
            }
            try {
              final j = json.decode(raw) as Map<String, dynamic>;
              final p = PairPayload.fromJson(j);     // can throw (we catch below)
              setState(() {
                payload = p;
                _handledScan = true;
                step = 2;                             // go to “Connect to setup Wi-Fi”
              });
            } catch (e) {
              setState(() => error = "Invalid QR: $e");
            }
          },
        ),
      ),
      if (error != null)
        Padding(
          padding: const EdgeInsets.all(12),
          child: Text(error!, style: const TextStyle(color: Colors.red)),
        ),
      const SizedBox(height: 8),
    ]);
  }

  Widget _stepConnectAP() {
    if (payload == null) {
      // user navigated here without a valid scan
      return _inlineError("Please scan the QR first", backTo: 1);
    }

    final p = payload!;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text("Connect to setup Wi-Fi", style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        Text("Join this temporary Wi-Fi network:\n\nSSID: ${p.ssid}\nPassword: ${p.psk}"),
        const SizedBox(height: 12),
        const Text("After connecting, return to this app."),
        const Spacer(),
        Row(children: [
          TextButton(onPressed: () => setState(() => step = 1), child: const Text("Back")),
          const Spacer(),
          FilledButton(onPressed: () => setState(() => step = 3), child: const Text("I’m connected")),
        ]),
      ]),
    );
  }

  Widget _stepEnterHomeWifi() {
    if (payload == null) {
      return _inlineError("Please scan the QR first", backTo: 1);
    }
    final p = payload!;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text("Your home Wi-Fi", style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        TextField(controller: ssidCtrl, decoration: const InputDecoration(labelText: "Home Wi-Fi SSID")),
        const SizedBox(height: 8),
        TextField(controller: passCtrl, decoration: const InputDecoration(labelText: "Password"), obscureText: true),
        const SizedBox(height: 12),
        if (error != null) Text(error!, style: const TextStyle(color: Colors.red)),
        const Spacer(),
        Row(children: [
          TextButton(onPressed: () => setState(() => step = 2), child: const Text("Back")),
          const Spacer(),
          FilledButton.icon(
            onPressed: posting ? null : () async {
              setState(() { posting = true; error = null; });
              try {
                final res = await http.post(
                  Uri.parse("${p.setupBase}/provision"),
                  headers: {"Content-Type":"application/json"},
                  body: json.encode({
                    "pair_code": p.pairCode,
                    "wifi": {"ssid": ssidCtrl.text.trim(), "password": passCtrl.text.trim()},
                  }),
                );
                if (res.statusCode == 200) {
                  setState(() => step = 4);
                } else {
                  setState(() => error = "Provision failed: ${res.statusCode} ${res.body}");
                }
              } catch (e) {
                setState(() => error = "Network error: $e");
              } finally {
                setState(() => posting = false);
              }
            },
            icon: posting ? const SizedBox(width:16,height:16,child:CircularProgressIndicator(strokeWidth:2)) : const Icon(Icons.check),
            label: const Text("Connect"),
          ),
        ]),
      ]),
    );
  }

  Widget _inlineError(String msg, {required int backTo}) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(msg, style: const TextStyle(color: Colors.red)),
          const Spacer(),
          Row(children: [
            const Spacer(),
            FilledButton(
              onPressed: () => setState(() => step = backTo),
              child: const Text("Go back"),
            ),
          ]),
        ],
      ),
    );
  }

  Widget _stepDone() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text("All set!", style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        const Text("Your frame is joining your home Wi-Fi. Reconnect your phone to your normal Wi-Fi."),
        const SizedBox(height: 8),
        const Text("Then open Home → Settings (gear) and press Connect."),
        const Spacer(),
        Row(children: [
          const Spacer(),
          FilledButton(onPressed: () => Navigator.pop(context), child: const Text("Finish")),
        ]),
      ]),
    );
  }
}

extension<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}


/// ----------------------------------------------------------------------------
/// QR code payload for initial setup
/// ----------------------------------------------------------------------------
class PairPayload {
  final String ssid, psk, pairCode, deviceId, setupBase;
  PairPayload(this.ssid, this.psk, this.pairCode, this.deviceId, this.setupBase);

  factory PairPayload.fromJson(Map<String, dynamic> j) {
    final kind = j["kind"] ?? "leanframe_setup_v1";
    if (kind != "leanframe_setup_v1") {
      throw Exception("Unsupported QR kind '$kind'");
    }
    String req(String k) {
      final v = j[k];
      if (v is String && v.isNotEmpty) return v;
      throw Exception("QR is missing '$k'");
    }
    return PairPayload(
      req("ap_ssid"),
      req("ap_psk"),
      req("pair_code"),
      req("device_id"),
      req("setup_base"),
    );
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
/// Home (system picker; new UI tweaks)
/// ----------------------------------------------------------------------------
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

enum HubTab { photos, settings}

class _HomeScreenState extends State<HomeScreen> {
  HubTab tab = HubTab.photos;

  @override
  Widget build(BuildContext context) {
    final state = InheritedAppState.of(context);

    // ✅ compute this BEFORE returning the widget tree
    final bool needsSetup = state.serverBase == null || !state.connected;

    return Scaffold(
      drawer: const _AppDrawer(),
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                state.frameName,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
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
                  initialBase: state.serverBase ?? "http://192.168.1.104:8765",
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

          // ✅ Use collection-if here (no declarations inside the list)
          if (needsSetup)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Card(
                color: Colors.amber.shade100,
                child: ListTile(
                  leading: const Icon(Icons.qr_code_2),
                  title: const Text("Set up your new frame"),
                  subtitle: const Text("Scan QR, join setup Wi-Fi, and provision"),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const FirstRunWizard()),
                    );
                  },
                ),
              ),
            ),

          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: CupertinoSegmentedControl<HubTab>(
              groupValue: tab,
              onValueChanged: (v) => setState(() => tab = v),
              children: const {
                HubTab.photos: Padding(
                  padding: EdgeInsets.all(8),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.grid_on, size: 16), SizedBox(width: 6), Text("Photos")
                  ]),
                ),
                HubTab.settings: Padding(
                  padding: EdgeInsets.all(8),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.settings, size: 16), SizedBox(width: 6), Text("Settings")
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
            child: tab == HubTab.photos
                ? const _PhotoGrid()
                : const FrameSettingsTab(),
          ),
        ],
      ),

      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: SizedBox(
            width: double.infinity,
            height: 56,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.amber,
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              onPressed: () async => _runSystemPickerFlow(context),
              icon: const Icon(Icons.add),
              label: const Text("Add Photos"),
            ),
          ),
        ),
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

/// Drawer with two sections:
///  - Section 1: App name + '>' right-aligned
///  - Section 2: Frame name + green/gray indicator
class _AppDrawer extends StatelessWidget {
  const _AppDrawer();

  @override
  Widget build(BuildContext context) {
    final state = InheritedAppState.of(context);
    final dotColor = state.connected ? Colors.green : Colors.grey;

    return Drawer(
      child: SafeArea(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            // Section 1
            ListTile(
              title: Row(
                children: [
                  const Expanded(
                    child: Text(
                      "LeanFrame",
                      style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
                    ),
                  ),
                  const Text(">", style: TextStyle(fontSize: 16)),
                ],
              ),
              onTap: () => Navigator.pop(context), // no-op; reserved for future
            ),
            const Divider(height: 1),

            // Section 2
            ListTile(
              leading: Icon(Icons.smart_display, color: dotColor),
              title: Text(
                state.frameName,
                style: const TextStyle(fontWeight: FontWeight.w500),
              ),
              trailing: Icon(
                Icons.circle,
                color: dotColor,
                size: 12,
              ),
              onTap: () => Navigator.pop(context),
            ),

            // (Optional) More items later:
            const SizedBox(height: 8),
            const Divider(height: 1),
            const ListTile(
              leading: Icon(Icons.info_outline),
              title: Text("About"),
            ),
          ],
        ),
      ),
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

class FrameSettingsTab extends StatefulWidget {
  const FrameSettingsTab({super.key});
  @override
  State<FrameSettingsTab> createState() => _FrameSettingsTabState();
}

class _FrameSettingsTabState extends State<FrameSettingsTab> {
  RuntimeConfig? cfg;
  bool saving = false;
  String? error;

  // temp UI state bindings
  late String _mode;
  late String _style;
  late String _colorHex;
  double _blur = 16;
  double _slideS = 12;
  bool _shuffle = false;
  bool _loop = true;
  int _crossfadeMs = 300;
  bool _loadedOnce = false; 

  static const _allStyles = <String>[
    "solid",
    "blur",
    "average",
    "mirror",
    "stretch",
    "gradient_linear",
    "gradient_radial",
    "glass",
    "motion",
    "texture",
    "dim",
  ];

  // Helpers for conditional controls
  bool get _usesBlur => _style == "blur" || _style == "glass";
  bool get _styleUsesColor => _style == "solid" || _style == "gradient_linear" || _style == "gradient_radial";

  String _labelForStyle(String s) {
    switch (s) {
      case "solid": return "Solid color";
      case "blur": return "Blur";
      case "average": return "Average color";
      case "mirror": return "Mirror pad";
      case "stretch": return "Stretch edges";
      case "gradient_linear": return "Gradient (linear)";
      case "gradient_radial": return "Gradient (radial)";
      case "glass": return "Glass (blurred tint)";
      case "motion": return "Motion smear";
      case "texture": return "Texture (grain)";
      case "dim": return "Dimmed avg";
      default: return s;
    }
  }

  @override
  void initState() { super.initState(); }


  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loadedOnce) {
      _loadedOnce = true;
      // Safe: runs after the element is mounted so Inherited lookups work
      _load();
    }
  }


  Future<void> _load() async {
    final state = InheritedAppState.of(context);
    if (state.serverBase == null) { setState(() => error = "Set Server URL/Token in settings."); return; }
    try {
      final api = Api(state.serverBase!, state.authToken);
      final r = await api.getRuntime();
      setState(() {
        cfg = r;
        _mode = r.mode;
        _style = r.paddingStyle;
        _colorHex = r.paddingColor;
        _blur = r.blurAmount;
        _slideS = r.slideDurationS;
        _shuffle = r.shuffle;
        _loop = r.loop;
        _crossfadeMs = r.crossfadeMs;
      });
    } catch (e) {
      setState(() => error = "Failed to load: $e");
    }
  }

  Future<void> _save() async {
    final state = InheritedAppState.of(context);
    if (state.serverBase == null) return;
    setState(() { saving = true; error = null; });
    try {
      final api = Api(state.serverBase!, state.authToken);
      final ok = await api.putRuntime(RuntimeConfig(
        mode: _mode,
        paddingStyle: _style,         // includes "glass"
        paddingColor: _colorHex,      // only used when "solid"
        blurAmount: _usesBlur ? _blur : 0.0,
        slideDurationS: _slideS,
        shuffle: _shuffle,
        loop: _loop,
        crossfadeMs: _crossfadeMs,
      ));

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ok ? "Saved" : "Save failed")),
      );
      if (!ok) setState(() => error = "Save failed");
    } catch (e) {
      setState(() => error = "Save error: $e");
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (error != null) {
      final app = InheritedAppState.of(context);
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              error!,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              icon: const Icon(Icons.settings),
              label: const Text("Open server settings"),
              onPressed: () async {
                final out = await showDialog<_ServerCfg>(
                  context: context,
                  builder: (_) => _ServerConfigDialog(
                    initialBase: app.serverBase ?? "http://192.168.1.104:8765",
                    initialToken: app.authToken,
                  ),
                );
                if (out != null) {
                  app.setServer(base: out.base, token: out.token);
                  final up = await Api(out.base, out.token).ping();
                  app.setConnection(up);
                  if (!mounted) return;
                  if (up) {
                    setState(() {
                      error = null;  // clear the error so UI can load
                      cfg = null;    // force spinner then reload
                    });
                    _load();         // fetch /config/runtime
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text("Server not reachable")),
                    );
                  }
                }
              },
            ),
          ],
        ),
      );
    }

    if (cfg == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 100),
      children: [
        Text("Render", style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),

        // 1.1 Mode: cover / contain
        Row(children: [
          const SizedBox(width: 140, child: Text("Fit mode")),
          const SizedBox(width: 12),
          DropdownButton<String>(
            value: _mode,
            items: const [
              DropdownMenuItem(value: "cover", child: Text("Cover")),
              DropdownMenuItem(value: "contain", child: Text("Contain")),
            ],
            onChanged: (v) => setState(() => _mode = v!),
          ),
        ]),
        const SizedBox(height: 8),

        // 1.2/1.3 Padding style + 1.4 Color (if solid) + 1.5 Blur (if blur)
        Row(children: [
          const SizedBox(width: 140, child: Text("Padding style")),
          const SizedBox(width: 12),
          DropdownButton<String>(
            value: _style,
            items: _allStyles
                .map((s) => DropdownMenuItem(value: s, child: Text(_labelForStyle(s))))
                .toList(),
            onChanged: (v) => setState(() => _style = v!),
          ),
        ]),
        const SizedBox(height: 8),

        // if (_style == "solid")
        //   Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        //     const SizedBox(width: 140, child: Text("Color")),
        //     const SizedBox(width: 12),
        //     GestureDetector(
        //       onTap: () async {
        //         Color current = _parseHex(_colorHex);
        //         final picked = await showDialog<Color>(
        //           context: context,
        //           builder: (_) => AlertDialog(
        //             title: const Text("Pick color"),
        //             content: SingleChildScrollView(child: BlockPicker(
        //               pickerColor: current,
        //               onColorChanged: (c) => current = c,
        //             )),
        //             actions: [
        //               TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
        //               FilledButton(onPressed: () => Navigator.pop(context, current), child: const Text("Select")),
        //             ],
        //           ),
        //         );
        //         if (picked != null) setState(() => _colorHex = _toHex(picked));
        //       },
        //       child: Container(
        //         width: 48, height: 28, decoration: BoxDecoration(
        //           color: _parseHex(_colorHex),
        //           borderRadius: BorderRadius.circular(6),
        //           border: Border.all(color: Colors.black12),
        //         ),
        //       ),
        //     ),
        //     const SizedBox(width: 12),
        //     Expanded(child: Text(_colorHex)),
        //   ]),

        if (_styleUsesColor)
          Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
            const SizedBox(width: 140, child: Text("Color")),
            const SizedBox(width: 12),
            GestureDetector(
              onTap: () async {
                Color current = _parseHex(_colorHex);
                final picked = await showDialog<Color>(
                  context: context,
                  builder: (_) => AlertDialog(
                    title: const Text("Pick color"),
                    content: SingleChildScrollView(
                      child: BlockPicker(
                        pickerColor: current,
                        onColorChanged: (c) => current = c,
                      ),
                    ),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
                      FilledButton(onPressed: () => Navigator.pop(context, current), child: const Text("Select")),
                    ],
                  ),
                );
                if (picked != null) setState(() => _colorHex = _toHex(picked));
              },
              child: Container(
                width: 48, height: 28,
                decoration: BoxDecoration(
                  color: _parseHex(_colorHex),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.black12),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(child: Text(_colorHex)),
          ]),

        if (_usesBlur)
          Row(children: [
            const SizedBox(width: 140, child: Text("Blur amount")),
            const SizedBox(width: 12),
            Expanded(
              child: Slider(
                min: 0, max: 64, divisions: 64,
                value: _blur,
                label: _blur.toStringAsFixed(0),
                onChanged: (v) => setState(() => _blur = v),
              ),
            ),
            SizedBox(
              width: 70,
              child: TextField(
                controller: TextEditingController(text: _blur.toStringAsFixed(0)),
                keyboardType: TextInputType.number,
                onSubmitted: (s) {
                  final v = double.tryParse(s) ?? _blur;
                  setState(() => _blur = v.clamp(0, 64));
                },
              ),
            ),
          ]),

        const SizedBox(height: 24),
        Text("Playback", style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),

        // 2.1 Slide duration (seconds)
        Row(children: [
          const SizedBox(width: 140, child: Text("Slide duration (s)")),
          const SizedBox(width: 12),
          Expanded(
            child: Slider(
              min: 1, max: 120, divisions: 119,
              value: _slideS,
              label: _slideS.toStringAsFixed(0),
              onChanged: (v) => setState(() => _slideS = v),
            ),
          ),
          SizedBox(
            width: 70,
            child: TextField(
              controller: TextEditingController(text: _slideS.toStringAsFixed(0)),
              keyboardType: TextInputType.number,
              onSubmitted: (s) {
                final v = double.tryParse(s) ?? _slideS;
                setState(() => _slideS = v.clamp(1, 120));
              },
            ),
          ),
        ]),

        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text("Shuffle"),
          value: _shuffle,
          onChanged: (v) => setState(() => _shuffle = v),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text("Loop"),
          value: _loop,
          onChanged: (v) => setState(() => _loop = v),
        ),

        const SizedBox(height: 8),
        Row(children: [
          const SizedBox(width: 140, child: Text("Crossfade (ms)")),
          const SizedBox(width: 12),
          Expanded(
            child: Slider(
              min: 0, max: 3000, divisions: 60,
              value: _crossfadeMs.toDouble(),
              label: _crossfadeMs.toString(),
              onChanged: (v) => setState(() => _crossfadeMs = v.round()),
            ),
          ),
          SizedBox(
            width: 90,
            child: TextField(
              controller: TextEditingController(text: _crossfadeMs.toString()),
              keyboardType: TextInputType.number,
              onSubmitted: (s) {
                final v = int.tryParse(s) ?? _crossfadeMs;
                setState(() => _crossfadeMs = v.clamp(0, 10000));
              },
            ),
          ),
        ]),

        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: saving ? null : _save,
          icon: saving ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.save),
          label: const Text("Save"),
        ),
      ],
    );
  }

  // helpers
  Color _parseHex(String hex) {
    final h = hex.replaceAll("#", "");
    final v = int.parse(h, radix: 16);
    return Color(0xFF000000 | v);
  }
  String _toHex(Color c) {
    final argb = c.toARGB32();          // 0xAARRGGBB
    final rgb  = argb & 0x00FFFFFF;     // strip alpha
    return "#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}";
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
