import 'dart:math';
import 'dart:typed_data';

import 'package:torrentia/reader.dart';
import 'package:torrentia/utils.dart';

/// Magic protocol id that starts every UDP connect request (BEP 15).
const int udpProtocolId = 0x41727101980;

final _random = Random.secure();

int randomTransactionId() => _random.nextInt(1 << 32);

enum AnnounceEvent {
  none(0, null),
  completed(1, 'completed'),
  started(2, 'started'),
  stopped(3, 'stopped');

  final int udpCode;
  final String? httpName;
  const AnnounceEvent(this.udpCode, this.httpName);
}

/// Transfer stats reported to the tracker.
class AnnounceParams {
  final int downloaded;
  final int uploaded;
  final int left;
  final AnnounceEvent event;
  final int port;
  final int numWant;

  /// Our peer id; defaults to the process-wide id.
  final Uint8List? peerId;

  const AnnounceParams({
    required this.downloaded,
    required this.uploaded,
    required this.left,
    this.event = AnnounceEvent.none,
    this.port = 6881,
    this.numWant = 80,
    this.peerId,
  });

  Uint8List get effectivePeerId => peerId ?? TorrentiaUtils.generateId();

  AnnounceParams withEvent(AnnounceEvent e) => AnnounceParams(
        downloaded: downloaded,
        uploaded: uploaded,
        left: left,
        event: e,
        port: port,
        numWant: numWant,
        peerId: peerId,
      );
}

/// UDP connect request: protocol_id(8) action=0(4) transaction_id(4)
Uint8List buildConnReq(int transactionId) {
  final buffer = Uint8List(16);
  ByteData.sublistView(buffer)
    ..setUint64(0, udpProtocolId)
    ..setUint32(8, 0)
    ..setUint32(12, transactionId);
  return buffer;
}

/// UDP announce request (BEP 15), 98 bytes.
Uint8List buildAnnounceRequest({
  required int connId,
  required int transactionId,
  required TorrentContent torrent,
  required AnnounceParams params,
  int key = 0,
}) {
  final buffer = Uint8List(98);
  final view = ByteData.sublistView(buffer);

  view.setUint64(0, connId);
  view.setUint32(8, 1); // action: announce
  view.setUint32(12, transactionId);
  buffer.setRange(16, 36, torrent.infoHash);
  buffer.setRange(36, 56, params.effectivePeerId);
  view.setUint64(56, params.downloaded);
  view.setUint64(64, params.left);
  view.setUint64(72, params.uploaded);
  view.setUint32(80, params.event.udpCode);
  view.setUint32(84, 0); // IP: let the tracker use the packet's source address
  view.setUint32(88, key);
  view.setInt32(92, params.numWant);
  view.setUint16(96, params.port);
  return buffer;
}

/// Builds the HTTP(S) announce URL, keeping any query already on [trackerUrl]
/// (private trackers put passkeys there).
Uri buildHttpConnectionRequest({
  required String trackerUrl,
  required TorrentContent torrent,
  required AnnounceParams params,
}) {
  final base = Uri.parse(trackerUrl);
  final query = [
    if (base.query.isNotEmpty) base.query,
    'info_hash=${_percentEncodeBytes(torrent.infoHash)}',
    'peer_id=${_percentEncodeBytes(params.effectivePeerId)}',
    'port=${params.port}',
    'uploaded=${params.uploaded}',
    'downloaded=${params.downloaded}',
    'left=${params.left}',
    'compact=1',
    'numwant=${params.numWant}',
    if (params.event.httpName != null) 'event=${params.event.httpName}',
  ].join('&');

  return base.replace(query: query);
}

String _percentEncodeBytes(Uint8List bytes) =>
    bytes.map((b) => '%${b.toRadixString(16).padLeft(2, '0')}').join();
