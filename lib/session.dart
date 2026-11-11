import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:torrentia/network/builders.dart';
import 'package:torrentia/parser.dart';
import 'package:torrentia/peer_connection.dart';
import 'package:torrentia/piece_manager.dart';
import 'package:torrentia/reader.dart';
import 'package:torrentia/storage.dart';
import 'package:torrentia/tracker.dart';
import 'package:torrentia/utils.dart';
import 'package:torrentia/web_seed.dart';

const videoExtensions = {'mp4', 'm4v', 'mkv', 'webm', 'avi', 'mov', 'ts', 'm2ts', 'mpg', 'mpeg', 'wmv', 'flv', 'ogv'};

class SessionOptions {
  /// Where downloaded files go.
  final String outputDir;

  /// TCP port to accept peers on (0 = any free port).
  final int listenPort;
  final int maxPeers;
  final int uploadSlots;
  final bool useTrackers;
  final bool useWebSeeds;

  /// Allow trackers/torrents to point us at LAN or loopback addresses.
  /// Off by default; see [NetworkPolicy].
  final bool allowPrivateNetworks;

  /// [PieceStrategy.streaming] for watching, [PieceStrategy.rarestFirst] for
  /// fastest full downloads.
  final PieceStrategy strategy;

  const SessionOptions({
    this.strategy = PieceStrategy.streaming,
    this.outputDir = 'downloads',
    this.listenPort = 6881,
    this.maxPeers = 60,
    this.uploadSlots = 4,
    this.useTrackers = true,
    this.useWebSeeds = true,
    this.allowPrivateNetworks = false,
  });
}

/// A running torrent: finds peers, downloads pieces, and exposes data for streaming.
class TorrentSession {
  final TorrentContent torrent;
  final SessionOptions options;

  /// This session's peer id.
  final Uint8List peerId = TorrentiaUtils.newPeerId();
  late final Storage storage;
  late final PieceManager manager;
  late final TrackerManager trackers;
  late final UploadSlots _uploadSlots = UploadSlots(options.uploadSlots);
  final webSeeds = <WebSeed>[];

  final _connections = <String, PeerConnection>{};
  final _candidates = Queue<Peer>();
  final _known = <String>{};
  final _retryAt = <String, DateTime>{};

  /// IPs that sent corrupt data. Never reconnected or accepted again.
  final bannedIps = <String>{};
  static const _maxConnectionsPerIp = 3;
  final _completed = Completer<void>();
  ServerSocket? _server;
  Timer? _timer;
  StreamSubscription<List<Peer>>? _trackerSub;
  DateTime _lastForcedAnnounce = DateTime.fromMillisecondsSinceEpoch(0);
  bool _started = false;
  bool _closed = false;

  int _receivedAtLastTick = 0;
  double downloadRate = 0;

  TorrentSession(this.torrent, this.options) {
    if (options.allowPrivateNetworks) NetworkPolicy.allowPrivateNetworks = true;
    storage = Storage(torrent, options.outputDir);
    manager = PieceManager(torrent, storage, strategy: options.strategy);
    trackers = TrackerManager(torrent, stats: _announceParams);
  }

  static Future<TorrentSession> load(String torrentPath, [SessionOptions options = const SessionOptions()]) async =>
      TorrentSession(await Reader().readFromFile(torrentPath), options);

  /// Completes when every wanted piece is downloaded.
  Future<void> get whenComplete => _completed.future;

  int get listenPort => _server?.port ?? 0;
  int get connectedPeers => _connections.values.where((c) => c.isConnected).length;
  int get uploaded => _connections.values.fold(0, (s, c) => s + c.uploaded);

  /// The file to stream by default: the largest video file, else the largest file.
  int get defaultFileIndex {
    final files = torrent.info.files;
    int best(Iterable<int> idx) => idx.reduce((a, b) => files[a].size >= files[b].size ? a : b);
    final videos = [
      for (var i = 0; i < files.length; i++)
        if (videoExtensions.contains(files[i].name.split('.').last.toLowerCase())) i
    ];
    return best(videos.isNotEmpty ? videos : List.generate(files.length, (i) => i));
  }

  /// Download only [fileIndex] in the background. When streaming, its first and
  /// last pieces come early (video containers keep headers/indexes there).
  void selectFile(int fileIndex) {
    final file = torrent.info.files[fileIndex];
    final (first, last) = torrent.info.piecesForFile(file);
    manager.setWanted([for (var i = first; i <= last; i++) i]);
    _checkComplete();
    if (options.strategy != PieceStrategy.streaming) return;
    final edge = max(1, (2 * 1024 * 1024 / torrent.info.pieceLength).ceil());
    manager.setHighPriority({
      for (var i = first; i < min(first + edge, last + 1); i++) i,
      for (var i = max(first, last - edge + 1); i <= last; i++) i,
    });
    _checkComplete();
  }

  Future<void> start() async {
    if (_started) return;
    _started = true;

    final existing = await storage.verifyExisting();
    if (existing.isNotEmpty) {
      manager.markHave(existing);
      Log.info('Resumed ${existing.length}/${torrent.info.pieceCount} pieces from disk');
    }
    manager.onPieceVerified.listen(_onPieceVerified);
    _checkComplete();

    try {
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, options.listenPort);
    } on SocketException {
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    }
    _server!.listen(_accept, onError: (Object e) => Log.debug('Listen error: $e'));

    if (options.useTrackers) {
      _trackerSub = trackers.peers.listen((peers) => addPeers(peers, trusted: false));
      trackers.start();
    }
    if (options.useWebSeeds) {
      for (final url in torrent.urlList) {
        webSeeds.add(WebSeed(url, torrent, manager, storage)..start());
      }
      if (webSeeds.isNotEmpty) Log.info('Using ${webSeeds.length} web seed(s)');
    }
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _maintain());
  }

  AnnounceParams _announceParams() => AnnounceParams(
        downloaded: manager.verifiedBytes,
        uploaded: uploaded,
        left: max(0, torrent.size - manager.verifiedBytes),
        port: listenPort == 0 ? options.listenPort : listenPort,
        peerId: peerId,
      );

  /// Adds peer addresses to connect to. Untrusted lists (from trackers) are
  /// filtered by [NetworkPolicy] so they can't aim us at the local network;
  /// addresses you add yourself are trusted.
  void addPeers(Iterable<Peer> peers, {bool trusted = true}) {
    for (final p in peers) {
      if (bannedIps.contains(p.ip)) continue;
      if (!trusted) {
        final addr = InternetAddress.tryParse(p.ip);
        if (addr == null || !NetworkPolicy.isAllowed(addr)) continue;
      }
      if (_known.add(p.key)) _candidates.add(p);
    }
    _maintain();
  }

  void _maintain() {
    if (_closed) return;
    final now = DateTime.now();

    // Re-queue peers whose retry cooldown has expired.
    final ready = _retryAt.entries.where((e) => now.isAfter(e.value)).map((e) => e.key).toList();
    for (final key in ready) {
      _retryAt.remove(key);
      final i = key.lastIndexOf(':');
      _candidates.add(Peer(ip: key.substring(0, i), port: int.parse(key.substring(i + 1))));
    }

    while (_connections.length < options.maxPeers && _candidates.isNotEmpty && !manager.isComplete) {
      final peer = _candidates.removeFirst();
      if (_connections.containsKey(peer.key) || bannedIps.contains(peer.ip)) continue;
      final conn = _newConnection(peer);
      _connections[peer.key] = conn;
      unawaited(conn.start());
    }

    if (options.useTrackers &&
        connectedPeers < 5 &&
        !manager.isComplete &&
        now.difference(_lastForcedAnnounce) > const Duration(minutes: 1) &&
        _connections.isNotEmpty) {
      _lastForcedAnnounce = now;
      trackers.announceNow();
    }

    final received = manager.receivedBytes;
    downloadRate = downloadRate * 0.6 + (received - _receivedAtLastTick) * 0.4;
    _receivedAtLastTick = received;
  }

  PeerConnection _newConnection(Peer peer, [Socket? socket]) => PeerConnection(
        peer: peer,
        torrent: torrent,
        manager: manager,
        storage: storage,
        uploadSlots: _uploadSlots,
        socket: socket,
        localPeerId: peerId,
        onClosed: _onConnectionClosed,
      );

  void _onConnectionClosed(PeerConnection conn, String reason) {
    if (_connections[conn.peer.key] == conn) _connections.remove(conn.peer.key);
    if (conn.banned) {
      bannedIps.add(conn.peer.ip);
      for (final c in _connections.values.where((c) => c.peer.ip == conn.peer.ip).toList()) {
        c.close('banned IP');
      }
      return;
    }
    if (_closed || conn.inbound) return;
    // Retry good peers soon, unreachable ones much later.
    final wasUseful = conn.downloaded > 0;
    _retryAt[conn.peer.key] = DateTime.now().add(Duration(seconds: wasUseful ? 15 : 300));
  }

  void _accept(Socket socket) {
    final peer = Peer(ip: socket.remoteAddress.address, port: socket.remotePort);
    final sameIp = _connections.values.where((c) => c.peer.ip == peer.ip).length;
    if (_closed ||
        bannedIps.contains(peer.ip) ||
        sameIp >= _maxConnectionsPerIp ||
        _connections.length >= options.maxPeers + 10 ||
        _connections.containsKey(peer.key)) {
      socket.destroy();
      return;
    }
    final conn = _newConnection(peer, socket);
    _connections[peer.key] = conn;
    unawaited(conn.start());
  }

  void _onPieceVerified(int piece) {
    for (final c in _connections.values) {
      if (c.isConnected) c.sendHave(piece);
    }
    _checkComplete();
  }

  void _checkComplete() {
    if (manager.isComplete && !_completed.isCompleted) {
      _completed.complete();
      Log.info('Download complete');
      if (_started && options.useTrackers) unawaited(trackers.completed());
    }
  }

  String statusLine() {
    final pct = manager.wantedCount == 0 ? 100.0 : manager.wantedHaveCount * 100 / manager.wantedCount;
    final activeWeb = webSeeds.where((w) => w.isActive).length;
    final webBytes = webSeeds.fold<int>(0, (s, w) => s + w.downloaded);
    return '${pct.toStringAsFixed(1)}% '
        '(${manager.wantedHaveCount}/${manager.wantedCount} pieces) | '
        '${TorrentiaUtils.formatBytes(downloadRate)}/s | '
        'peers $connectedPeers/${_connections.length}'
        '${activeWeb > 0 ? ' + $activeWeb web (${TorrentiaUtils.formatBytes(webBytes)})' : ''} | '
        'up ${TorrentiaUtils.formatBytes(uploaded)}'
        '${manager.isComplete ? '' : ' | ETA ${_eta()}'}';
  }

  String _eta() {
    if (downloadRate < 1024) return '--';
    final missing = (manager.wantedCount - manager.wantedHaveCount) * torrent.info.pieceLength;
    final s = (missing / downloadRate).round();
    if (s >= 3600) return '${s ~/ 3600}h${(s % 3600 ~/ 60).toString().padLeft(2, '0')}m';
    return '${s ~/ 60}m${(s % 60).toString().padLeft(2, '0')}s';
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _timer?.cancel();
    await _trackerSub?.cancel();
    for (final w in webSeeds) {
      w.stop();
    }
    for (final c in List.of(_connections.values)) {
      c.close('session closing');
    }
    await _server?.close();
    if (options.useTrackers) await trackers.stop();
    await storage.close();
    await manager.close();
  }
}
