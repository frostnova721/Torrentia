import 'dart:async';
import 'dart:math';

import 'package:torrentia/network/builders.dart';
import 'package:torrentia/network/requesters.dart';
import 'package:torrentia/parser.dart';
import 'package:torrentia/reader.dart';
import 'package:torrentia/utils.dart';

/// Announces to every supported tracker of a torrent in parallel, re-announces
/// on each tracker's interval, and publishes discovered peers on [peers].
class TrackerManager {
  final TorrentContent torrent;

  /// Returns current transfer stats for announces.
  final AnnounceParams Function() stats;

  final _peers = StreamController<List<Peer>>.broadcast();
  final _succeeded = <String>{};
  bool _running = false;
  Completer<void> _wake = Completer();

  int seeders = 0;
  int leechers = 0;

  TrackerManager(this.torrent, {required this.stats});

  /// Batches of peers, emitted as each tracker responds.
  Stream<List<Peer>> get peers => _peers.stream;

  List<String> get supportedTrackers => torrent.announceList.where(isSupportedTracker).toList();

  void start() {
    if (_running) return;
    _running = true;
    final unsupported = torrent.announceList.where((u) => !isSupportedTracker(u)).toList();
    if (unsupported.isNotEmpty) Log.debug('Skipping unsupported trackers: $unsupported');
    for (final url in supportedTrackers) {
      unawaited(_loop(url));
    }
  }

  /// Re-announce now instead of waiting for the interval (e.g. when short of peers).
  void announceNow() {
    if (!_wake.isCompleted) _wake.complete();
  }

  Future<void> _loop(String url) async {
    var event = AnnounceEvent.started;
    var failures = 0;
    while (_running) {
      Duration wait;
      try {
        final res = await sendAnnounceRequest(url, torrent, stats().withEvent(event));
        if (!_running) break;
        _succeeded.add(url);
        event = AnnounceEvent.none;
        failures = 0;
        seeders = max(seeders, res.seeders);
        leechers = max(leechers, res.leechers);
        if (res.warning != null) Log.warn('Tracker $url: ${res.warning}');
        Log.info('Tracker $url: ${res.peers.length} peers (${res.seeders} seeders, ${res.leechers} leechers)');
        if (res.peers.isNotEmpty) _peers.add(res.peers);
        wait = Duration(seconds: res.interval.clamp(60, 1800));
      } catch (e) {
        failures++;
        Log.debug('Tracker $url failed: $e');
        wait = Duration(seconds: min(30 * (1 << min(failures, 6)), 1800));
      }
      await Future.any([Future.delayed(wait), _wake.future]);
      if (_wake.isCompleted) _wake = Completer();
    }
  }

  /// Tells trackers that the download finished.
  Future<void> completed() => _broadcastEvent(AnnounceEvent.completed);

  /// Stops announcing and tells trackers we're leaving (best effort).
  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    announceNow();
    await _broadcastEvent(AnnounceEvent.stopped);
    await _peers.close();
  }

  Future<void> _broadcastEvent(AnnounceEvent event) async {
    final params = stats().withEvent(event);
    await Future.wait(_succeeded.map((url) => sendAnnounceRequest(url, torrent, params)
        .timeout(const Duration(seconds: 3))
        .then<void>((_) {}, onError: (_) {})));
  }
}
