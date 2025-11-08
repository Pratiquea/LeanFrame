import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';    // <-- for Uint8List
import 'dart:collection';    // <-- for LinkedHashMap

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:file_picker/file_picker.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:wifi_iot/wifi_iot.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:bonsoir/bonsoir.dart';

void main() => runApp(const LeanFrameApp());
final appStateSingleton = AppState();
/// ----------------------------------------------------------------------------
/// UI Spacing Constants
/// ----------------------------------------------------------------------------
class Gaps {
  static const xxs = 4.0;
  static const xs  = 8.0;
  static const sm  = 12.0;
  static const md  = 16.0;
  static const lg  = 20.0;
  static const xl  = 24.0;
}

/// ----------------------------------------------------------------------------
/// App State & API
/// ----------------------------------------------------------------------------
class AppState extends ChangeNotifier {
  String frameName = "My Frame";
  String? serverBase; // e.g. http://192.168.1.50:8765
  String authToken = "change-me";
  bool connected = false;

  final List<MediaItem> media = [];
  final List<LibEntry> library = [];
  void setLibrary(List<LibEntry> items) { library
    ..clear()
    ..addAll(items);
    notifyListeners();
  }

  int get imageCount => library.length;

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
      final res = await http.get(Uri.parse('$base/config/runtime'), headers: _headers)
                          .timeout(const Duration(seconds: 3));
      if (res.statusCode != 200) {
        debugPrint('Ping failed ${res.statusCode}: ${res.body}');
        return false;
      }
      return true;
    } catch (e) {
      debugPrint('Ping exception: $e');
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

class QrParseResult {
  final String? wifiSsid;
  final String? wifiPassword;
  final String? wifiAuth; // WPA/WEP/nopass
  final bool? wifiHidden;
  final Uri? setupBase;
  final Map<String, dynamic>? jsonPayload;
  QrParseResult({
    this.wifiSsid,
    this.wifiPassword,
    this.wifiAuth,
    this.wifiHidden,
    this.setupBase,
    this.jsonPayload,
  });
}

final _wifiRe = RegExp(
  r'^WIFI:'
  r'(?:T:(?<T>WPA|WEP|nopass);)?'
  r'(?:S:(?<S>[^;]*);)?'
  r'(?:P:(?<P>[^;]*);)?'
  r'(?:H:(?<H>true|false);)?'
  r'(?:;)*$',
);

QrParseResult parseQr(String raw) {
  final s = raw.trim();

  // 1) WIFI: schema (Android/iOS standard)
  final m = _wifiRe.firstMatch(s);
  if (m != null) {
    final ssid = m.namedGroup('S') ?? '';
    final pwd  = m.namedGroup('P') ?? '';
    final auth = m.namedGroup('T') ?? 'WPA';
    final hid  = (m.namedGroup('H') ?? 'false').toLowerCase() == 'true';

    // Optional: also look for an http URL in the same string (rare, but ok)
    Uri? setup;
    try {
      final maybeUrl = s.split(';').firstWhere(
        (p) => p.startsWith('http://') || p.startsWith('https://'),
        orElse: () => '',
      );
      setup = maybeUrl.isNotEmpty ? Uri.parse(maybeUrl) : null;
    } catch (_) {}

    return QrParseResult(
      wifiSsid: ssid,
      wifiPassword: pwd,
      wifiAuth: auth,
      wifiHidden: hid,
      setupBase: setup,
    );
  }

  // 2) JSON (your legacy/custom payload)
  try {
    final obj = jsonDecode(s) as Map<String, dynamic>;
    // If you want, validate a "kind" discriminator:
    // if (obj['kind'] != 'leanframe_setup_v1') throw FormatException('wrong kind');
    final base = (obj['setup_base'] is String) ? Uri.tryParse(obj['setup_base']) : null;
    return QrParseResult(
      jsonPayload: obj,
      setupBase: base,
      wifiSsid: obj['ap_ssid'],
      wifiPassword: obj['ap_psk'],
    );
  } catch (_) {
    // fall through
  }

  // 3) Plain URL (fallback)
  final u = Uri.tryParse(s);
  if (u != null && (u.isScheme('http') || u.isScheme('https'))) {
    return QrParseResult(setupBase: u);
  }

  // 4) Nothing matched
  throw FormatException('Invalid QR payload');
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
  // Wi-Fi scan + dropdown state 
  List<WifiNetwork> _nearby = const [];
  String? _selectedSsid;
  bool _scanning = false;
  bool _showPass = false;          // 👁 toggle for password field
  String _currSsid = "";           // live device Wi-Fi status
  String _currIp = "";             // live device Wi-Fi status
  BonsoirDiscovery? _discovery;
  StreamSubscription<BonsoirDiscoveryEvent>? _discSub;

  Future<void> _discoverFrameAndAutoConnect() async {
    try {
      // final app = InheritedAppState.maybeOf(context) ?? appStateSingleton;
      const String serviceType = '_leanframe._tcp'; // <-- match your frame's advertised type
      final discovery = BonsoirDiscovery(type: serviceType);
      _discovery = discovery;

      // v6: initialize() replaces the old "ready" getter
      await discovery.initialize();

      // Listen BEFORE starting
      _discSub = discovery.eventStream!.listen((event) async {
        if (event is BonsoirDiscoveryServiceFoundEvent) {
          // v6: resolve requires a resolver
          event.service!.resolve(discovery.serviceResolver);
        } else if (event is BonsoirDiscoveryServiceResolvedEvent) {
          final s = event.service!;
          // v6: no "ip" field; use addresses or host
          final Map<String, dynamic> j = s.toJson();
          final List addrs = (j['addresses'] as List?) ?? const [];
          final String host = addrs.isNotEmpty ? addrs.first as String : (s.host ?? '');
          final int port = s.port ?? 8765;
          if (host.isEmpty) return;

          final base = 'http://$host:$port';
          debugPrint('Discovered LeanFrame at $base');

          final app = InheritedAppState.of(context);
          app.setServer(base: base, token: app.authToken);
          final ok = await Api(base, app.authToken).ping();
          app.setConnection(ok);

          // Found one → stop discovery
          await _discovery?.stop();
          await _discSub?.cancel();
        }
        // Other events (updated/lost) can be ignored for this flow
      });

      await discovery.start();
    } catch (e) {
      debugPrint('mDNS discovery error: $e');
    }
  }

  Future<void> _readWifiStatus() async {
    try {
      final ssid = await WiFiForIoTPlugin.getSSID() ?? "";
      final ip   = await WiFiForIoTPlugin.getIP() ?? "";
      setState(() { _currSsid = ssid; _currIp = ip; });
      debugPrint("Wi-Fi status: ssid='$_currSsid' ip='$_currIp'");
    } catch (e) {
      debugPrint("Wi-Fi status error: $e");
    }
  }

  /// Try hard to connect to the target AP, and only return true when
  /// SSID == target and IP looks like 192.168.4.x
  Future<bool> _connectToApAndVerify({required String targetSsid, required String psk}) async {
    // Android requirements
    if (Platform.isAndroid) {
      final loc = await Permission.location.request();
      if (!loc.isGranted) {
        setState(() => error = "Location permission is required to connect Wi-Fi.");
        return false;
      }
      // Ensure Wi-Fi radio is ON
      if (!await WiFiForIoTPlugin.isEnabled()) {
        await WiFiForIoTPlugin.setEnabled(true);
      }
    }

    // If already on the AP, great
    await _readWifiStatus();
    if (_currSsid == targetSsid && _currIp.startsWith("192.168.4.")) {
      // ensure routing over Wi-Fi for local-only network
      if (Platform.isAndroid) await WiFiForIoTPlugin.forceWifiUsage(true);
      return true;
    }

    // Proactively disconnect from whatever we’re on (some OEMs cling)
    try { await WiFiForIoTPlugin.disconnect(); } catch (_) {}

    // Ask plugin to connect to our AP
    final ok = await WiFiForIoTPlugin.connect(
      targetSsid,
      password: psk,
      security: NetworkSecurity.WPA,
      joinOnce: true,         // don’t persist
      withInternet: false,    // local-only AP
    );

    if (!ok) {
      setState(() => error = "Couldn’t initiate connection to '$targetSsid'. Open Wi-Fi settings and join it, then return.");
      return false;
    }

    // Force sockets over this Wi-Fi even without internet
    if (Platform.isAndroid) {
      await WiFiForIoTPlugin.forceWifiUsage(true);
    }

    // Poll until actually connected to the right SSID + IP in 192.168.4.*
    final good = await _waitForApReady(
      wantSsid: targetSsid,
      wantSubnetPrefix: "192.168.4.",
      maxWait: const Duration(seconds: 25),
    );
    await _readWifiStatus(); // update banner

    return good;
  }


  Future<void> _refreshPairFromServer() async {
    // Must already be connected to the frame AP.
    final p = payload!;
    final uri = Uri.parse("${p.setupBase}/pair");
    try {
      final res = await http.get(uri).timeout(const Duration(seconds: 4));
      if (res.statusCode == 200) {
        final j = json.decode(res.body) as Map<String, dynamic>;
        final newPair = (j['pair_code'] as String?)?.trim();
        final dev     = (j['device_id'] as String?)?.trim();
        if (newPair != null && newPair.isNotEmpty) {
          // Rebuild payload with the real pair code (keep ssid/psk/setupBase/deviceId best-effort)
          setState(() {
            payload = PairPayload(
              p.ssid,
              p.psk,
              newPair,
              (dev?.isNotEmpty == true ? dev! : p.deviceId),
              p.setupBase,
            );
          });
        }
      } else {
        debugPrint("GET /pair -> ${res.statusCode} ${res.body}");
      }
    } catch (e) {
      debugPrint("GET /pair failed: $e");
    }
  }

  Future<bool> _waitForApReady({
  required String wantSsid,
  required String wantSubnetPrefix,
  Duration maxWait = const Duration(seconds: 20),
  }) async {
    final t0 = DateTime.now();
    while (DateTime.now().difference(t0) < maxWait) {
      try {
        final ssid = await WiFiForIoTPlugin.getSSID() ?? "";
        final ip   = await WiFiForIoTPlugin.getIP() ?? "";
        debugPrint("Wi-Fi status → SSID='$ssid' IP='$ip'");

        final onTarget = ssid == wantSsid && ip.startsWith(wantSubnetPrefix);
        if (onTarget) return true;
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 500));
    }
    return false;
  }

  Future<bool> _probeSetupBase(Uri url) async {
    try {
      final res = await http.get(url).timeout(const Duration(seconds: 3));
      debugPrint("Probe ${url} → ${res.statusCode}");
      return res.statusCode < 500;
    } catch (e) {
      debugPrint("Probe error: $e");
      return false;
    }
  }


  Future<void> _scanNearbyWifi() async {
    setState(() { _scanning = true; error = null; });
    try {
      // Android 10+: location permission is required to scan Wi-Fi
      if (Platform.isAndroid) {
        final st = await Permission.location.request();
        if (!st.isGranted) {
          setState(() { error = "Location permission is required to scan nearby Wi-Fi."; _scanning = false; });
          return;
        }
      }
      final list = await WiFiForIoTPlugin.loadWifiList(); // returns List<WifiNetwork>
      // De-duplicate by SSID, drop empties
      final ssids = <String>{};
      final cleaned = <WifiNetwork>[];
      for (final w in list) {
        final s = (w.ssid ?? '').trim();
        if (s.isEmpty) continue;
        if (ssids.add(s)) cleaned.add(w);
      }
      cleaned.sort((a,b) => (a.level ?? -100).compareTo(b.level ?? -100)); // weak→strong; reverse if you prefer
      setState(() {
        _nearby = cleaned.reversed.toList(); // strong→weak
        // keep previous selection if still visible
        if (_selectedSsid == null || !_nearby.any((w) => w.ssid == _selectedSsid)) {
          _selectedSsid = _nearby.isNotEmpty ? _nearby.first.ssid : null;
        }
      });
    } catch (e) {
      setState(() => error = "Scan error: $e");
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  @override
  void dispose() {
    _discSub?.cancel();
    _discovery?.stop();
    ssidCtrl.dispose();
    passCtrl.dispose();
    super.dispose();
  }

  void _onScan(String qrText) {
    try {
      final res = parseQr(qrText);

      final Uri setup = res.setupBase ?? Uri.parse('http://192.168.4.1:8765');
      final ssid = res.wifiSsid ?? (res.jsonPayload?['ap_ssid'] as String? ?? '');
      final psk  = res.wifiPassword ?? (res.jsonPayload?['ap_psk'] as String? ?? '');
      final pair = (res.jsonPayload?['pair_code'] as String?) ?? '0000';
      final dev  = (res.jsonPayload?['device_id'] as String?) ?? 'unknown';

      if (ssid.isEmpty || psk.isEmpty) {
        throw const FormatException('QR missing SSID/PSK');
      }

      setState(() {
        payload = PairPayload(ssid, psk, pair, dev, setup.toString());
        _handledScan = true;
        step = 2; // “Connect to setup Wi-Fi”
      });
    } catch (e) {
      setState(() => error = "Invalid QR: $e");
    }
  }

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
          if (_handledScan) return;
          final raw = capture.barcodes.firstOrNull?.rawValue;
          if (raw == null || raw.isEmpty) return;
          _onScan(raw);
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
        const SizedBox(height: Gaps.sm),
        Text("Join this temporary Wi-Fi network:\n\nSSID: ${p.ssid}\nPassword: ${p.psk}"),
        const SizedBox(height: 12),
        const Text("After connecting, return to this app."),
        const SizedBox(height: 12),
        FilledButton.icon(
          icon: const Icon(Icons.wifi),
          label: const Text("Connect now"),
          onPressed: () async {
            final p = payload!;
            setState(() { error = null; });

            final good = await _connectToApAndVerify(targetSsid: p.ssid, psk: p.psk);
            if (!good) {
              setState(() => error = "Wi-Fi didn’t fully connect. Check the password on the frame QR or try again.");
              return;
            }

            // We should now be on the AP. Double-check the setup server before proceeding.
            final probe = await _probeSetupBase(Uri.parse("${p.setupBase}/pair"));
            if (!probe) {
              setState(() => error = "Connected to '${p.ssid}', but ${p.setupBase} is not reachable. Stay on frame Wi-Fi and retry.");
              return;
            }

            // Pull the fresh pair code (in case placeholder)
            await _refreshPairFromServer();

            if (mounted) setState(() => step = 3);
          }
        ),
        const Spacer(),
        const SizedBox(height: Gaps.sm),
        /// Controls + status stacked vertically (no Row here)
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                TextButton(
                  onPressed: () => setState(() => step = 1),
                  child: const Text("Back"),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: () => setState(() => step = 3),
                  child: const Text("I’m connected"),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.03),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.black12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text("Phone connection status", style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: Gaps.xs),
                  Text("SSID: ${_currSsid.isEmpty ? '—' : _currSsid}"),
                  Text("IP:   ${_currIp.isEmpty   ? '—' : _currIp}"),
                  const SizedBox(height: Gaps.xs),
                  Align(
                    alignment: Alignment.centerRight,
                    child: OutlinedButton.icon(
                      onPressed: _readWifiStatus,
                      icon: const Icon(Icons.refresh, size: 16),
                      label: const Text("Refresh"),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ]),
    );
  }

  Widget _stepEnterHomeWifi() {
    if (payload == null) {
      return _inlineError("Please scan the QR first", backTo: 1);
    }
    // Best-effort: if we still have a placeholder, refresh pair_code on step entry.
    if (payload!.pairCode == '0000' || payload!.pairCode.trim().isEmpty) {
      // fire and forget; UI doesn't block
      _refreshPairFromServer();
    }

    final p = payload!;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text("Your home Wi-Fi", style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),

        //  Android gets a dropdown of nearby SSIDs
        //  Android gets a dropdown of nearby SSIDs
        if (Platform.isAndroid) ...[
          Row(children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                isExpanded: true,
                value: _selectedSsid,
                hint: const Text("Select a Wi-Fi network"),
                items: _nearby.map((w) {
                  final s = (w.ssid ?? '').trim();
                  // we already filtered empties in _scanNearbyWifi()
                  return DropdownMenuItem<String>(
                    value: s,                      // <- non-null
                    child: Text(s, overflow: TextOverflow.ellipsis),
                  );
                }).toList(),
                onChanged: (v) => setState(() {
                  _selectedSsid = v;
                  if ((v ?? '').isNotEmpty) {
                    ssidCtrl.text = v!;           // keep the text field in sync
                  }
                }),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: _scanning ? null : _scanNearbyWifi,
              icon: _scanning
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.wifi_find),
              label: const Text("Scan"),
            ),
          ]),
          const SizedBox(height: 8),
        ],


        // iOS fallback OR manual override: allow entering SSID if needed 
        if (!Platform.isAndroid) ...[
          TextField(controller: ssidCtrl, decoration: const InputDecoration(labelText: "Home Wi-Fi SSID")),
          const SizedBox(height: 8),
          const Text("Tip: iOS doesn’t permit apps to list nearby SSIDs; enter your network name.", style: TextStyle(fontSize: 12, color: Colors.black54)),
          const SizedBox(height: 8),
        ],

        TextField(
          controller: passCtrl,
          decoration: InputDecoration(
            labelText: "Password",
            suffixIcon: IconButton(
              tooltip: _showPass ? "Hide password" : "Show password",
              icon: Icon(_showPass ? Icons.visibility_off : Icons.visibility),
              onPressed: () => setState(() => _showPass = !_showPass),
            ),
          ),
          obscureText: !_showPass,
        ),

        const SizedBox(height: 12),

        if (error != null) Text(error!, style: const TextStyle(color: Colors.red)),

        const Spacer(),
        Row(children: [
          TextButton(onPressed: () => setState(() => step = 2), child: const Text("Back")),
          const Spacer(),
          FilledButton.icon(
            icon: posting
                ? const SizedBox(width:16,height:16,child:CircularProgressIndicator(strokeWidth:2))
                : const Icon(Icons.check),
            label: const Text("Connect"),
            onPressed: posting ? null : () async {
              setState(() { posting = true; error = null; });
              final p = payload!;
              try {
                // Make sure we’re still on the AP
                final probeOk = await _probeSetupBase(Uri.parse("${p.setupBase}/status"));
                if (!probeOk) {
                  setState(() => error = "Not connected to the frame’s Wi-Fi. Stay on '${p.ssid}' while provisioning.");
                  return;
                }

                // Ensure we have a real pair code (not the "0000" placeholder)
                if (p.pairCode == '0000' || p.pairCode.trim().isEmpty) {
                  await _refreshPairFromServer();
                }

                // Use dropdown on Android; text field elsewhere
                final homeSsid = Platform.isAndroid ? (_selectedSsid ?? '') : ssidCtrl.text.trim();
                if (homeSsid.isEmpty) {
                  setState(() => error = "Please select/enter your home Wi-Fi SSID.");
                  return;
                }
                final payloadBody = {
                  "pair_code": payload!.pairCode, // may have been updated by _refreshPairFromServer()
                  "wifi": {"ssid": homeSsid, "password": passCtrl.text.trim()},
                };

                Future<http.Response> _post() => http
                    .post(
                      Uri.parse("${payload!.setupBase}/provision"),
                      headers: {"Content-Type":"application/json"},
                      body: json.encode(payloadBody),
                    )
                    .timeout(const Duration(seconds: 8));

                http.Response res = await _post();

                // If backend says 400 (e.g., stale/invalid code), fetch new pair_code once and retry once
                if (res.statusCode == 400) {
                  await _refreshPairFromServer(); // update payload!.pairCode if changed
                  final retryBody = {
                    "pair_code": payload!.pairCode,
                    "wifi": {"ssid": homeSsid, "password": passCtrl.text.trim()},
                  };
                  res = await http
                      .post(
                        Uri.parse("${payload!.setupBase}/provision"),
                        headers: {"Content-Type":"application/json"},
                        body: json.encode(retryBody),
                      )
                      .timeout(const Duration(seconds: 8));
                }

                if (res.statusCode == 200) {
                  if (mounted) {
                    setState(() => step = 4);
                    // Fire and forget: discover the frame on the home network and auto-fill Server URL.
                    _discoverFrameAndAutoConnect();
                  }
                } else {
                  setState(() => error = "Provision failed: ${res.statusCode} ${res.body}");
                }
              } catch (e) {
                setState(() => error = "Network error: $e");
              } finally {
                if (mounted) setState(() => posting = false);
              }
            },
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      autoDiscoverAndConnect(context);
    });
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
        notifier: appStateSingleton,
        child: const HomeScreen(),
      ),
    );
  }
}

class InheritedAppState extends InheritedNotifier<AppState> {
  const InheritedAppState({
    super.key,
    required super.notifier,
    required super.child,
  });

  /// Non-listening lookup. Useful in async callbacks when widget may be gone.
  static AppState? maybeOf(BuildContext context) {
    final inh = context.getElementForInheritedWidgetOfExactType<InheritedAppState>()
        ?.widget as InheritedAppState?;
    return inh?.notifier;
  }

  /// Listening lookup (rebuilds on changes). Falls back to global singleton.
  static AppState of(BuildContext context) {
    final n = context.dependOnInheritedWidgetOfExactType<InheritedAppState>()
        ?.notifier;
    return n ?? appStateSingleton;
  }
}


/// ----------------------------------------------------------------------------
/// Home (system picker; new UI tweaks)
/// ----------------------------------------------------------------------------
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.thisdiscoverOverride});

  /// If provided, this is used instead of _refreshAndDiscover().
  final Future<void> Function()? thisdiscoverOverride;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

enum HubTab { photos, settings}

class _HomeScreenState extends State<HomeScreen> {
  HubTab tab = HubTab.photos;
  StorageStats? _storage;
  bool _loadingStorage = false;

  Future<void> _refreshAndDiscover({int tries = 2}) async {
    final app = InheritedAppState.of(context);
    for (int i = 0; i < tries; i++) {
      await autoDiscoverAndConnect(context);
      // if (app.serverBase != null && app.connected) break;
      if (app.serverBase != null && app.connected) {
        final items = await Api(app.serverBase!, app.authToken).listLibrary();
        if (mounted) InheritedAppState.of(context).setLibrary(items);
      }
      await Future.delayed(const Duration(milliseconds: 400));
    }
    if (!mounted) return;
    // fetch storage if we have a server
    if (app.serverBase != null) {
      setState(() => _loadingStorage = true);
      try {
        final s = await Api(app.serverBase!, app.authToken).getStorageStats();
        if (mounted) setState(() => _storage = s);
      } finally {
        if (mounted) setState(() => _loadingStorage = false);
      }
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshAndDiscover(tries: 2);
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = InheritedAppState.of(context);

    // compute this BEFORE returning the widget tree
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
            tooltip: 'Find connected device',
            icon: const Icon(Icons.refresh),
            onPressed: () {
              final fn = widget.thisdiscoverOverride ?? (() => _refreshAndDiscover());
              fn();
            },
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

          // Use collection-if here (no declarations inside the list)
          if (needsSetup)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gaps.md),
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
            padding: const EdgeInsets.symmetric(horizontal: Gaps.md, vertical: Gaps.xs),
            child: _loadingStorage
                ? const SizedBox(height: 12, child: LinearProgressIndicator())
                : (_storage == null
                    ? const SizedBox(height: 12) // keep layout even if stats missing
                    : StorageBar(stats: _storage!)),
          ),
          
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gaps.md),
            child: LayoutBuilder(
              builder: (context, constraints) {
                const double kSegHeight = 48; // tweak (40–48 feels nice)
                final totalWidth = constraints.maxWidth;
                final segmentWidth = totalWidth / 2;

                return CupertinoSegmentedControl<HubTab>(
                  groupValue: tab,
                  onValueChanged: (v) => setState(() => tab = v),
                  // Optional: tighter outer padding so height is driven by children
                  padding: const EdgeInsets.all(2),
                  children: {
                    HubTab.photos: SizedBox(
                      width: segmentWidth,
                      height: kSegHeight,
                      child: const Center(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.grid_on, size: 18),
                            SizedBox(width: 6),
                            Text("Memories"),
                          ],
                        ),
                      ),
                    ),
                    HubTab.settings: SizedBox(
                      width: segmentWidth,
                      height: kSegHeight,
                      child: const Center(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.settings, size: 18),
                            SizedBox(width: 6),
                            Text("Frame Controls"),
                          ],
                        ),
                      ),
                    ),
                  },
                );
              },
            ),
          ),


          const SizedBox(height: Gaps.sm),
          if (tab == HubTab.photos)
            _PhotosHeaderRow(count: state.imageCount)
          else
            const _ActivityPlaceholder(),
          const SizedBox(height: Gaps.xs),
          const Divider(height: 1),
          const SizedBox(height: Gaps.xs),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () {
                final fn = widget.thisdiscoverOverride ?? (() => _refreshAndDiscover());
                return fn();
              },
              child: tab == HubTab.photos
                  ? const _PhotoGrid()
                  : const FrameSettingsTab(),
            ),
          ),
        ],
      ),

      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Gaps.md, Gaps.xs,Gaps.md, 12),
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
              label: const Text("Add Photos & Videos"),
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
    // immediately refresh the on-device library so the grid updates
    try {
      // tiny delay helps if the backend needs a beat to index the uploads
      await Future.delayed(const Duration(milliseconds: 250));
      final fresh = await api.listLibrary();
      InheritedAppState.of(context).setLibrary(fresh); // triggers grid rebuild
    } catch (_) {
      // ignore; fall back to periodic poll or manual refresh
    }

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
          padding: const EdgeInsets.symmetric(horizontal: Gaps.md),
          children: [
            // Section 1
            ListTile(
              title: Row(
                children: const [
                  Expanded(
                    child: Text(
                      "LeanFrame",
                      style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
                    ),
                  ),
                  Text(">", style: TextStyle(fontSize: 16)),
                ],
              ),
              onTap: () => Navigator.pop(context),
            ),
            const Divider(height: 1),

            // Section 2
            ListTile(
              leading: Icon(Icons.smart_display, color: dotColor),
              title: Text(
                state.frameName,
                style: const TextStyle(fontWeight: FontWeight.w500),
              ),
              trailing: Icon(Icons.circle, color: dotColor, size: 12),
              onTap: () => Navigator.pop(context),
            ),

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
    final state = InheritedAppState.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gaps.md, Gaps.xs, Gaps.md, Gaps.xs),
      // padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          Text("Media ($count)", style: const TextStyle(fontWeight: FontWeight.w600)),
          const Spacer(),
          Tooltip(
            message: (!state.connected)
                ? "Connect to your frame first"
                : (state.library.isEmpty ? "No items to select" : ""),
            child: OutlinedButton.icon(
              onPressed: (state.connected && state.library.isNotEmpty)
                  ? () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => SelectionEditor(entries: List.of(state.library)),
                        ),
                      );
                    }
                  : null, // disabled if not connected or no items
              icon: const Icon(Icons.check_box),
              label: const Text("Select"),
            )
          )
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
      child: Align(alignment: Alignment.centerLeft, child: Text("Controls")),
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

class _PhotoGrid extends StatefulWidget {
  const _PhotoGrid();
  @override
  State<_PhotoGrid> createState() => _PhotoGridState();
}

class _PhotoGridState extends State<_PhotoGrid> {
  final _thumbs = ThumbCache(cap: 160);
  final _loading = <String, bool>{}; // prevent duplicate fetches
  Timer? _pollTimer;
  int? _rev; // last seen

  @override
  void initState() {
    super.initState();
    _startPolling();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) => _checkForChanges());
  }

  Future<void> _checkForChanges() async {
    final app = InheritedAppState.of(context);
    if (app.serverBase == null || !app.connected) return;
    final api = Api(app.serverBase!, app.authToken);

    final rev = await api.getLibraryRev();
    if (rev == null) return;

    if (_rev == null) {
      _rev = rev; // prime without fetch
      return;
    }
    if (rev == _rev) return;

    // rev changed -> fetch listing silently, diff, update
    final list = await api.listLibrary();
    if (!mounted) return;

    // compute diff against app.library
    final old = { for (final e in app.library) e.id : e };
    final now = { for (final e in list) e.id : e };

    // removed
    for (final id in old.keys) {
      if (!now.containsKey(id)) {
        _thumbs.get(id); // optional: evict or keep; no-op here
      }
    }

    InheritedAppState.of(context).setLibrary(list);
    _rev = rev;
  }

  Future<Uint8List?> _ensureThumb(BuildContext ctx, LibEntry e) async {
    final app = InheritedAppState.maybeOf(ctx) ?? appStateSingleton;
    final cached = _thumbs.get(e.id);
    if (cached != null) return cached;
    if (_loading[e.id] == true) return null;
    _loading[e.id] = true;
    try {
      final b = await Api(app.serverBase!, app.authToken).fetchThumb(e.id, maxW: 360);
      if (b != null) {
        _thumbs.put(e.id, b);
        if (mounted) setState(() {}); // refresh this tile later
      }
      return b;
    } finally {
      _loading[e.id] = false;
    }
  }

  Future<void> _openActions(BuildContext ctx, LibEntry e) async {
    final app = InheritedAppState.maybeOf(ctx) ?? appStateSingleton;
    final api = Api(app.serverBase!, app.authToken);
    final choice = await showModalBottomSheet<String>(
      context: ctx,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.block), dense: true,
            title: const Text("Exclude from shuffle"),
            onTap: () => Navigator.pop(ctx, "Exclude from shuffle"),
          ),
          ListTile(
            leading: const Icon(Icons.check_circle), dense: true,
            title: const Text("Include in slideshow"),
            onTap: () => Navigator.pop(ctx, "Include in slideshow"),
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline,color: Colors.red), dense: true,
            title: const Text("Remove from frame",
              style: TextStyle(color: Colors.red, fontWeight: FontWeight.w600)),
            onTap: () => Navigator.pop(ctx, "Remove from frame"),
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );

    if (choice == null) return;

    late bool ok;
    switch (choice) {
      case "Remove from frame":
        final sure = await _confirmDelete(ctx, count: 1);
        if (!sure) return;
        ok = await api.deleteItem(e.id);
        if (ok) {
          final list = [...app.library]..removeWhere((x) => x.id == e.id);
          app.setLibrary(list);
          _thumbs.get(e.id); // keep or drop; optional to evict
        }
        break;
      case "Exclude from shuffle":
        ok = await api.setFlags(e.id, excludeFromShuffle: true);
        break;
      case "Include in slideshow":
        ok = await api.setFlags(e.id, include: true, excludeFromShuffle: false);
        break;
      default:
        return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(ctx).showSnackBar(
      SnackBar(content: Text(ok ? "Done" : "Action failed")),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = InheritedAppState.of(context);
    final items = app.library;
    if (app.serverBase == null || !app.connected) {
      return const Center(child: Text("Not connected. Use the gear to connect or pull to refresh."));
    }
    if (items.isEmpty) {
      return const Center(child: Text("No media on the frame yet."));
    }

    return RefreshIndicator(
      onRefresh: () async {
        await autoDiscoverAndConnect(context);
        if (app.serverBase != null) {
          final list = await Api(app.serverBase!, app.authToken).listLibrary();
          if (mounted) InheritedAppState.of(context).setLibrary(list);
        }
      },
      child: GridView.builder(
        padding: const EdgeInsets.all(Gaps.xs),
        // gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 180.0,
          mainAxisSpacing: Gaps.xs,
          crossAxisSpacing: Gaps.xs,
          childAspectRatio: 1),
        itemCount: items.length,
        itemBuilder: (_, i) {
          final e = items[i];
          final bytes = _thumbs.get(e.id);
          if (bytes == null) {
            // Start fetching in background
            _ensureThumb(context, e);
          }
          return GestureDetector(
            onLongPress: () => _openActions(context, e),
            onTap: () {
              // re-use your selection editor flow if needed
              // or toggle a local selected set (not shown here)
            },
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (bytes == null)
                  Container(color: Colors.grey.shade300, child: const Center(child: CircularProgressIndicator(strokeWidth: 2)))
                else
                  Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true, filterQuality: FilterQuality.medium),
                if (e.isVideo)
                  const Align(
                    alignment: Alignment.bottomRight,
                    child: Padding(
                      padding: EdgeInsets.all(4),
                      child: Icon(Icons.play_circle_fill, size: 24, color: Colors.white70),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}


class LibEntry {
  final String id;
  final String kind; // "image" | "video" | fallback
  final int bytes;
  LibEntry({required this.id, required this.kind, required this.bytes});
  factory LibEntry.fromJson(Map<String, dynamic> j) => LibEntry(
    id: j['id'] as String,
    kind: (j['kind'] as String?) ?? 'other',
    bytes: (j['bytes'] as int?) ?? 0,
  );
  bool get isVideo => kind.toLowerCase() == 'video';
  bool get isImage => kind.toLowerCase() == 'image';
}

extension ApiLibrary on Api {
  Future<List<LibEntry>> listLibrary() async {
    try {
      final res = await http.get(Uri.parse("$base/library"), headers: _headers)
                            .timeout(const Duration(seconds: 5));
      if (res.statusCode == 200) {
        final j = json.decode(res.body) as Map<String, dynamic>;
        final items = (j['items'] as List? ?? const []);
        return items.map((e) => LibEntry.fromJson(e as Map<String, dynamic>)).toList();
      }
    } catch (_) {}
    return const [];
  }

  Future<Uint8List?> fetchThumb(String id, {int maxW = 300}) async {
    try {
      final res = await http.get(Uri.parse("$base/thumb/$id?w=$maxW"), headers: _headers)
                            .timeout(const Duration(seconds: 5));
      if (res.statusCode == 200) return res.bodyBytes;
    } catch (_) {}
    return null;
  }

  Future<bool> deleteItem(String id) async {
    try {
      final res = await http.delete(Uri.parse("$base/library/$id"), headers: _headers)
                            .timeout(const Duration(seconds: 5));
      return res.statusCode == 200 || res.statusCode == 204;
    } catch (_) { return false; }
  }

  Future<bool> setFlags(String id, {bool? include, bool? excludeFromShuffle}) async {
    try {
      final body = <String, dynamic>{};
      if (include != null) body['include'] = include;
      if (excludeFromShuffle != null) body['exclude_from_shuffle'] = excludeFromShuffle;
      final res = await http.post(
        Uri.parse("$base/library/$id/flags"),
        headers: {..._headers, "Content-Type": "application/json"},
        body: json.encode(body),
      ).timeout(const Duration(seconds: 5));
      return res.statusCode == 200;
    } catch (_) { return false; }
  }
}

// A tiny in-memory LRU for thumbnails (by count, not bytes).
class ThumbCache {
  final int cap;
  final _map = LinkedHashMap<String, Uint8List>();
  ThumbCache({this.cap = 128});
  Uint8List? get(String k) {
    final v = _map.remove(k);
    if (v != null) _map[k] = v; // move to end
    return v;
  }
  void put(String k, Uint8List v) {
    if (_map.containsKey(k)) _map.remove(k);
    _map[k] = v;
    while (_map.length > cap) {
      _map.remove(_map.keys.first);
    }
  }
}

class StorageBar extends StatelessWidget {
  final StorageStats stats;
  const StorageBar({super.key, required this.stats});

  // Soft, high-contrast pastels (match your existing palette)
  static const _imagesColor = Color(0xFF00C194); // cyan
  static const _videosColor = Color(0xFFFF5591); // pink
  static const _otherColor  = Color.fromARGB(255, 190, 190, 190); // Light gray
  // static const _freeColor   = Color(0xFFE0F2F1); // Ligher gray(free)
  static const _freeColor   = Color(0xFFF5F5F5); // Ligher gray(free)


  // Format bytes -> MB/GB with 1 decimal place (GB preferred, else MB)
  String _fmtBytes(int bytes) {
    if (bytes <= 0) return "0 MB";
    final gb = bytes / (1024 * 1024 * 1024);
    if (gb >= 1) return "${gb.toStringAsFixed(1)} GB";
    final mb = bytes / (1024 * 1024);
    return "${mb.toStringAsFixed(1)} MB";
  }

  @override
  Widget build(BuildContext context) {
    final int total = stats.total;
    final int img   = stats.images.clamp(0, total);
    final int vid   = stats.videos.clamp(0, total);
    final int oth   = stats.other.clamp(0, total);
    final int used = (img + vid + oth).clamp(0, total);
    final int free = (total - used).clamp(0, total);

    final totalLabel = "Total: ${_fmtBytes(total)}";

    if (total == 0) {
      // Graceful empty state
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Header(totalLabel: totalLabel),
          const SizedBox(height: 8),
          _EmptyBar(),
          const SizedBox(height: 8),
          _Legend(img: 0, vid: 0, oth: 0, free: 0, fmt: _fmtBytes),
        ],
      );
    }

    // ---- Compute proportional flex with a minimum for visibility ----
    // Scale for Flex math (bigger = smoother proportions)
    const scale = 1000;
    // Minimum visual segment for non-zero images/videos (~2% each)
    const minFlexUnit = 20;

    int prop(int part) => ((part / total) * scale).round();

    int imgFlex = img > 0 ? prop(img) : 0;
    int vidFlex = vid > 0 ? prop(vid) : 0;
    int othFlex  = oth > 0? prop(oth) : 0;
    int freeFlex   = free > 0 ? prop(free) : 0;

    // Enforce minimums on images/videos if they’re non-zero
    if (img > 0 && imgFlex < minFlexUnit) imgFlex = minFlexUnit;
    if (vid > 0 && vidFlex < minFlexUnit) vidFlex = minFlexUnit;

    // Rebalance "other" to keep total == scale
    int sum = imgFlex + vidFlex + othFlex + freeFlex;

    if (sum != scale) {
      // Put the remainder mostly into FREE first (so free visibly expands),
      // then into OTHER; if negative, take from OTHER then FREE.
      int delta = scale - sum;
      if (delta > 0) {
        final giveFree = delta ~/ 2;
        freeFlex += giveFree;
        othFlex  += (delta - giveFree);
      } else if (delta < 0) {
        int need = -delta;
        final takeFromOth  = (othFlex - 0).clamp(0, need);
        othFlex -= takeFromOth; need -= takeFromOth;
        if (need > 0) {
          final takeFromFree = (freeFlex - 0).clamp(0, need);
          freeFlex -= takeFromFree; need -= takeFromFree;
        }
        // If still need > 0 (extreme tiny totals), trim from vid then img but keep >=1
        if (need > 0) {
          final takeFromVid = (vidFlex - 1).clamp(0, need);
          vidFlex -= takeFromVid; need -= takeFromVid;
        }
        if (need > 0) {
          final takeFromImg = (imgFlex - 1).clamp(0, need);
          imgFlex -= takeFromImg; need -= takeFromImg;
        }
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Header(totalLabel: totalLabel),
        const SizedBox(height: 8),
        // Full stacked bar: Images | Videos | Other | Free  == Total
        Container(
          height: 12,
          decoration: BoxDecoration(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: Colors.black12),
          ),
          clipBehavior: Clip.antiAlias,
          child: Row(
            children: [
              if (imgFlex  > 0) Flexible(flex: imgFlex,  child: Container(color: _imagesColor)),
              if (vidFlex  > 0) Flexible(flex: vidFlex,  child: Container(color: _videosColor)),
              if (othFlex  > 0) Flexible(flex: othFlex,  child: Container(color: _otherColor)),
              if (freeFlex > 0) Flexible(flex: freeFlex, child: Container(color: _freeColor)),
            ],
          ),
        ),
        const SizedBox(height: 8),
        _Legend(img: img, vid: vid, oth: oth, free: free, fmt: _fmtBytes),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  final String totalLabel;
  const _Header({required this.totalLabel});
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text("Storage", style: Theme.of(context).textTheme.titleMedium),
        const Spacer(),
        Text(totalLabel, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

class _Legend extends StatelessWidget {
  final int img, vid, oth, free;
  final String Function(int)? fmt;
  const _Legend({required this.img, required this.vid, required this.oth, required this.free, this.fmt});

  @override
  Widget build(BuildContext context) {
    String f(int b) => fmt != null ? fmt!(b) : "$b B";

    Widget _dot(Color c) => Container(
        width: 12,
        height: 12,
        decoration: BoxDecoration(
          color: c,
          shape: BoxShape.circle,
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant, // subtle black outline
            width: 1.5,                           // thin border, not harsh
          ),
        ),
      );

    Widget _item(Color c, String label, String value) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _dot(c),
            const SizedBox(width: 6),
            Flexible(child: Text("$label: $value", overflow: TextOverflow.ellipsis)),
          ],
        );

     return LayoutBuilder(
      builder: (context, constraints) {
        const spacing = 16.0;
        // 2 columns on normal/wide; collapse to 1 on very narrow widths
        final cols = constraints.maxWidth < 320 ? 1 : 2;
        final itemWidth = (constraints.maxWidth - spacing * (cols - 1)) / cols;

        final children = <Widget>[
          _item(StorageBar._imagesColor, "Images", f(img)),
          _item(StorageBar._videosColor, "Videos", f(vid)),
          _item(StorageBar._otherColor,  "Other",  f(oth)),
          _item(StorageBar._freeColor,   "Free",   f(free)),
        ].map((w) => SizedBox(width: itemWidth, child: w)).toList();

    return Wrap(
          spacing: spacing,
          runSpacing: 6,
          children: children,
        );
      },
    );
  }
}

class _EmptyBar extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      height: 12,
      decoration: BoxDecoration(
        // Empty track with border to keep layout
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.black12),
      ),
    );
  }
}

class _SettingRow extends StatelessWidget {
  final String label;
  final Widget control;
  const _SettingRow({required this.label, required this.control});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (ctx, c) {
        if (c.maxWidth < 360) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label),
              const SizedBox(height: Gaps.xs),
              control,
            ],
          );
        }
        return Row(
          children: [
            SizedBox(width: 140, child: Text(label)),
            const SizedBox(width: Gaps.sm),
            Expanded(child: control),
          ],
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
  void initState() {
    super.initState(); 
    WidgetsBinding.instance.addPostFrameCallback((_) {
      autoDiscoverAndConnect(context);
      //  _refreshAndDiscover(tries: 2);
    });
  }


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
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(Gaps.md, Gaps.md, Gaps.md, 100),
      children: [
        Text("Render", style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: Gaps.sm),

        // 1.1 Mode: cover / contain
        _SettingRow(
            label: "Fit mode",
            control: DropdownButton<String>(
              value: _mode,
              items: const [
                DropdownMenuItem(value: "cover", child: Text("Cover")),
                DropdownMenuItem(value: "contain", child: Text("Contain")),
              ],
              onChanged: (v) => setState(() => _mode = v!),
            ),
          ),

        const SizedBox(height: Gaps.xs),

        // 1.2/1.3 Padding style + 1.4 Color (if solid) + 1.5 Blur (if blur)
        _SettingRow(
            label: "Padding style",
            control: DropdownButton<String>(
              value: _style,
              items: _allStyles
                  .map((s) => DropdownMenuItem(value: s, child: Text(_labelForStyle(s))))
                  .toList(),
              onChanged: (v) => setState(() => _style = v!),
            ),
          ),
        const SizedBox(height: Gaps.xs),

        if (_styleUsesColor)
          _SettingRow(
            label: "Color",
            control: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
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
          ),

        if (_usesBlur)
        _SettingRow(
            label: "Blur amount",
            control: Row(children: [
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
          ),

        const SizedBox(height: Gaps.xl),
        Text("Playback", style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: Gaps.xs),

        // 2.1 Slide duration (seconds)
        _SettingRow(
            label: "Slide duration (s)",
            control: Row(children: [
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
          ),

        const SizedBox(height: Gaps.xs),
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

        const SizedBox(height: Gaps.xs),
        _SettingRow(
          label: "Crossfade duration (ms)",
          control: Row(children: [
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
        ),

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
/// Storage stats model 
/// ----------------------------------------------------------------------------
class StorageStats {
  final int total, used, images, videos, other;
  StorageStats({required this.total, required this.used, required this.images, required this.videos, required this.other});
    
    int get free => (total - used).clamp(0, total);

    factory StorageStats.fromJson(Map<String, dynamic> j) {
    final total = (j['total_bytes'] ?? 0) as int;
    final images = (j['images_bytes'] ?? 0) as int;
    final videos = (j['videos_bytes'] ?? 0) as int;
    // If backend gives `used_bytes`, trust it; else compute from parts.
    int used = (j['used_bytes'] ?? 0) as int;
    int other = (j['other_bytes'] ?? 0) as int;
    
    if (used <= 0){
      // compute 'other' if missing; then derive 'used'
      if (other <= 0) other = (images + videos);
      used = (images + videos + other);
    } else {
      // ensure 'other' is consistent if present
      if (other <= 0) other = (used - images - videos).clamp(0, used);
    }
    return StorageStats(total: total, used: used, images: images, videos: videos, other: other);
  }
}

extension ApiStorage on Api {
  // Backend: GET /stats/storage -> {"total_bytes":..., "images_bytes":..., "videos_bytes":..., "other_bytes":...}
  Future<StorageStats?> getStorageStats() async {
    try {
      final res = await http.get(Uri.parse("$base/stats/storage"), headers: _headers)
                            .timeout(const Duration(seconds: 3));
      if (res.statusCode == 200) {
        return StorageStats.fromJson(json.decode(res.body));
      }
    } catch (_) {}
    return null; // gracefully hide if backend doesn’t have it
  }
}

extension ApiRev on Api {
  Future<int?> getLibraryRev() async {
    try {
      final r = await http.get(Uri.parse("$base/library/rev"), headers: _headers)
                          .timeout(const Duration(seconds: 3));
      if (r.statusCode == 200) return (json.decode(r.body)['rev'] as num).toInt();
    } catch (_) {}
    return null;
  }
}

/// ----------------------------------------------------------------------------
/// Selection editor (for already-uploaded grid items; optional stub)
/// ----------------------------------------------------------------------------
class SelectionEditor extends StatefulWidget {
  final List<LibEntry> entries;
  const SelectionEditor({super.key, required this.entries});

  @override
  State<SelectionEditor> createState() => _SelectionEditorState();
}

class _SelectionEditorState extends State<SelectionEditor> {
  final Set<String> selected = {};
  final Map<String, Uint8List> _thumbs = {};
  final Set<String> _loading = {};

  Future<void> _loadThumb(String id) async {
    if (_thumbs.containsKey(id) || _loading.contains(id)) return;
    _loading.add(id);
    try {
      final app = InheritedAppState.maybeOf(context) ?? appStateSingleton;
      if (app.serverBase == null) return;
      final b = await Api(app.serverBase!, app.authToken).fetchThumb(id, maxW: 360);
      if (b != null && mounted) setState(() => _thumbs[id] = b);
    } finally {
      _loading.remove(id);
    }
  }

  Future<void> _doBulkAction(String action) async {
    final app = InheritedAppState.maybeOf(context) ?? appStateSingleton;
    if (app.serverBase == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Not connected. Open the gear and connect to your frame.")),
      );
      return;
    }
    final api = Api(app.serverBase!, app.authToken);

    int ok = 0, fail = 0;
    for (final id in selected.toList()) {
      bool res = true;
      switch (action) {
        case "include":
          res = await api.setFlags(id, include: true, excludeFromShuffle: false);
          break;
        case "exclude":
          res = await api.setFlags(id, excludeFromShuffle: true);
          break;
        case "remove":
          res = await api.deleteItem(id);
          if (res) {
            widget.entries.removeWhere((e) => e.id == id);
            _thumbs.remove(id);
          }
          break;
      }
      res ? ok++ : fail++;
    }

    if (!mounted) return;
    setState(() => selected.clear());
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text("Done: $ok${fail > 0 ? " failed: $fail" : ""}")),
    );
    Navigator.pop(context); // back to grid
    // (only if still mounted & connected)
    if (app.serverBase != null) {
      final items = await Api(app.serverBase!, app.authToken).listLibrary();
      if (context.mounted) InheritedAppState.of(context).setLibrary(items);
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.entries;

    return Scaffold(
      appBar: AppBar(
        leadingWidth: 92, // ← gives "Cancel" enough room (no wrap)
        leading: TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text(
            "Cancel",
            softWrap: false,
            maxLines: 1,
          ),
        ),
        title: Text("${selected.length} selected"),
        actions: [
          TextButton(
            onPressed: selected.isEmpty
                ? null
                : () async {
                    final action = await showModalBottomSheet<String>(
                      context: context,
                      showDragHandle: true,
                      builder: (_) => SafeArea(
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          ListTile(
                            leading: const Icon(Icons.block),
                            title: const Text("Exclude from slideshow"),
                            onTap: () => Navigator.pop(context, "exclude"),
                          ),
                          ListTile(
                            leading: const Icon(Icons.slideshow),
                            title: const Text("Include in slideshow"),
                            onTap: () => Navigator.pop(context, "include"),
                          ),
                          ListTile(
                            leading: const Icon(Icons.delete_outline, color: Colors.red),
                            title: const Text("Remove from frame",
                                style: TextStyle(color: Colors.red, fontWeight: FontWeight.w600)),
                            onTap: () => Navigator.pop(context, "remove"),
                          ),
                          const SizedBox(height: 8),
                        ]),
                      ),
                    );
                    if (action == null) return;
                    if (action == "remove") {
                      final sure = await _confirmDelete(context, count: selected.length);
                      if (!sure) return;
                    }
                    _doBulkAction(action);
                  },
            child: Text(
              "Next",
              style: TextStyle(color: selected.isEmpty ? Colors.grey : Colors.blue),
            ),
          ),
        ],
      ),
      body: GridView.builder(
        padding: const EdgeInsets.all(Gaps.xs),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3, mainAxisSpacing: 6, crossAxisSpacing: 6),
        itemCount: items.length,
        itemBuilder: (_, i) {
          final e = items[i];
          final isSel = selected.contains(e.id);
          final b = _thumbs[e.id];

          if (b == null) _loadThumb(e.id);

          return GestureDetector(
            onTap: () {
              setState(() {
                isSel ? selected.remove(e.id) : selected.add(e.id);
              });
            },
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (b == null)
                  Container(
                    color: Colors.grey.shade300,
                    child: const Center(
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                else
                  Image.memory(
                    b,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    filterQuality: FilterQuality.medium,
                  ),
                if (e.isVideo)
                  const Align(
                    alignment: Alignment.bottomRight,
                    child: Padding(
                      padding: EdgeInsets.all(4),
                      child: Icon(Icons.play_circle_fill, size: 20, color: Colors.white70),
                    ),
                  ),
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
        ListTile(
          leading: Icon(Icons.slideshow),
          title: Text("Include in slideshow"),
          // return key "include"
          subtitle: Text("Add to slideshow and allow shuffle"),
          // Using InkWell via ListTile tap:
          // We'll pop with "include" in onTap via a wrapper below
        ),
        ListTile(
          leading: Icon(Icons.block),
          title: Text("Exclude from slideshow"),
          subtitle: Text("Keep on device but skip during shuffle"),
        ),
        ListTile(
          leading: Icon(Icons.delete_outline, color: Colors.red),
          title: Text("Remove from frame"),
        ),
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
        padding: const EdgeInsets.fromLTRB(Gaps.md, 10, Gaps.md, Gaps.md),
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
Future<void> autoDiscoverAndConnect(
  BuildContext context, {
  Duration timeout = const Duration(seconds: 6),
}) async {
  final state = InheritedAppState.of(context);

  // If we already have a working base URL, keep it.
  if (state.serverBase != null) {
    try {
      final ok = await Api(state.serverBase!, state.authToken).ping();
      if (ok) {
        state.setConnection(true);
        return;
      }
    } catch (_) {}
  }

  final discovery = BonsoirDiscovery(type: '_leanframe._tcp');

  // v6: initialize() instead of "ready"
  await discovery.initialize();

  BonsoirService? chosen;

  // v6: type-checked events instead of BonsoirDiscoveryEventType enum
  final sub = discovery.eventStream!.listen((event) {
    if (event is BonsoirDiscoveryServiceFoundEvent) {
      // v6: resolve requires the resolver from the discovery instance
      event.service!.resolve(discovery.serviceResolver);
    } else if (event is BonsoirDiscoveryServiceResolvedEvent) {
      chosen ??= event.service!;
    }
  });

  await discovery.start();
  await Future<void>.delayed(timeout);
  await discovery.stop();
  await sub.cancel();

  if (chosen == null) {
    // Optional fallback to your known mDNS hostname
    final guess = 'http://radxa-zero3.local:8765';
    await _trySetBase(context, guess);
    return;
  }

  // v6: no "ip" getter; use addresses/host/port
  final Map<String, dynamic> j = chosen!.toJson();
  final List addrs = (j['addresses'] as List?) ?? const [];
  final String host = addrs.isNotEmpty ? addrs.first as String : (chosen!.host ?? '');
  final int port = chosen!.port ?? 8765;
  if (host.isEmpty) return;

  final base = 'http://$host:$port';
  await _trySetBase(context, base);
}

Future<bool> _trySetBase(BuildContext context, String base) async {
  final state = InheritedAppState.of(context);
  try {
    final res = await http
        .get(Uri.parse('$base/config/runtime'),
             headers: {'X-Auth-Token': state.authToken})
        .timeout(const Duration(seconds: 3));
    if (res.statusCode == 200) {
      state.setServer(base: base, token: state.authToken);
      state.setConnection(true);
      return true;
    }
  } catch (_) {}
  return false;
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

Future<bool> _confirmDelete(BuildContext context, {int count = 1}) async {
  final plural = count > 1 ? "items" : "item";
  return (await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text("Remove from frame?"),
          content: Text("This will remove $count $plural from the frame."),
          actions: [
            Padding(padding: EdgeInsets.only(right: Gaps.xs),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(onPressed: () => Navigator.pop(context, false), child: const Text("Cancel"),
                ),
                const SizedBox(width: Gaps.sm),
                FilledButton.tonal(
                  style: FilledButton.styleFrom(foregroundColor: Colors.red),
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text("Remove"),
              ),
              ],
            )
            ),
          ],
        )
      )) ??
      false;
}
