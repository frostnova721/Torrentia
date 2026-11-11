import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:test/test.dart';
import 'package:torrentia/torrentia.dart';

/// Builds a torrent for [files] (name -> data) and returns its bytes.
Uint8List makeTorrent(String name, Map<String, Uint8List> files, int pieceLength, {bool single = false}) {
  final all = BytesBuilder();
  for (final d in files.values) {
    all.add(d);
  }
  final data = all.toBytes();
  final hashes = BytesBuilder();
  for (var i = 0; i < data.length; i += pieceLength) {
    hashes.add(crypto.sha1.convert(data.sublist(i, min(i + pieceLength, data.length))).bytes);
  }
  final info = <String, dynamic>{
    'name': name,
    'piece length': pieceLength,
    'pieces': hashes.toBytes(),
    if (single) 'length': data.length,
    if (!single)
      'files': [
        for (final e in files.entries) {'length': e.value.length, 'path': e.key.split('/')}
      ],
  };
  return bencode({'announce': 'udp://tracker.example:1337/announce', 'info': info});
}

Uint8List randomBytes(int n, [int seed = 1]) {
  final r = Random(seed);
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

List<int> percentDecodeBytes(String s) {
  final out = <int>[];
  for (var i = 0; i < s.length; i++) {
    if (s[i] == '%') {
      out.add(int.parse(s.substring(i + 1, i + 3), radix: 16));
      i += 2;
    } else {
      out.add(s.codeUnitAt(i));
    }
  }
  return out;
}

class _FakeSource implements BlockSource {
  final cancelled = <BlockRequest>[];
  @override
  void cancelBlock(BlockRequest request) => cancelled.add(request);
  @override
  void onWorkAvailable() {}
  final hashFailures = <(int, bool)>[];
  @override
  void onHashFailure(int piece, {required bool sole}) => hashFailures.add((piece, sole));
}

void main() {
  if (Platform.environment["TT_DEBUG"] != null) Log.level = LogLevel.debug;
  group('bencode', () {
    test('round trips and records top-level spans', () {
      final encoded = bencode({'a': 1, 'info': {'x': 'y', 'n': [1, 2]}});
      final decoded = bdecode(encoded);
      expect(decoded.value['a'], 1);
      expect(decoded.value['info']['n'], [1, 2]);
      final (s, e) = decoded.topLevelSpans['info']!;
      expect(encoded.sublist(s, e), bencode({'x': 'y', 'n': [1, 2]}));
    });

    test('rejects garbage', () {
      expect(() => bdecode(Uint8List.fromList('d3:abc'.codeUnits)), throwsA(isA<BencodeException>()));
    });
  });

  group('Reader', () {
    test('parses the Big Buck Bunny torrent with the known info hash', () async {
      final t = await Reader().readFromFile('assets/big-buck-bunny.torrent');
      expect(t.infoHashHex, 'dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c');
      expect(t.info.files.map((f) => f.path), contains('Big Buck Bunny/Big Buck Bunny.mp4'));
      expect(t.urlList, ['https://webtorrent.io/torrents/']);
      expect(t.announceList.length, greaterThan(3));
      expect(t.size, t.info.files.fold<int>(0, (s, f) => s + f.size));
    });

    test('parses single-file torrents and nested paths', () {
      final single = Reader().parse(makeTorrent('movie.mkv', {'x': randomBytes(1000)}, 256, single: true));
      expect(single.info.files.single.path, 'movie.mkv');
      expect(single.info.pieceCount, 4);
      expect(single.info.pieceSize(3), 1000 - 768);

      final multi = Reader().parse(makeTorrent('pack', {'a/b/c.mp4': randomBytes(10), '../evil': randomBytes(5)}, 16));
      expect(multi.info.files[0].path, 'pack/a/b/c.mp4');
      expect(multi.info.files[1].pathSegments, isNot(contains('..')));
      expect(multi.info.files[1].offset, 10);
    });
  });

  group('tracker protocol', () {
    final torrent = Reader().parse(makeTorrent('t', {'x': randomBytes(5000)}, 1024, single: true));

    test('UDP announce request puts 64-bit "left" at offset 64', () {
      final req = buildAnnounceRequest(
        connId: 0x1122334455667788,
        transactionId: 42,
        torrent: torrent,
        params: const AnnounceParams(downloaded: 7, uploaded: 9, left: 5000000000, event: AnnounceEvent.started),
      );
      final v = ByteData.sublistView(req);
      expect(req.length, 98);
      expect(v.getUint64(0), 0x1122334455667788);
      expect(v.getUint32(8), 1);
      expect(v.getUint32(12), 42);
      expect(req.sublist(16, 36), torrent.infoHash);
      expect(v.getUint64(56), 7);
      expect(v.getUint64(64), 5000000000);
      expect(v.getUint64(72), 9);
      expect(v.getUint32(80), 2);
    });

    test('UDP connect request has the protocol magic', () {
      final v = ByteData.sublistView(buildConnReq(5));
      expect(v.getUint64(0), 0x41727101980);
      expect(v.getUint32(12), 5);
    });

    test('UDP announce response uses interval/leechers/seeders offsets 8/12/16', () {
      final res = Uint8List(32);
      ByteData.sublistView(res)
        ..setUint32(0, 1)
        ..setUint32(4, 99)
        ..setUint32(8, 1800)
        ..setUint32(12, 3)
        ..setUint32(16, 10);
      res.setAll(20, [1, 2, 3, 4, 0x1a, 0xe1, 5, 6, 7, 8, 0, 80]);
      final parsed = parseUdpAnnounceResponse(res, transactionId: 99);
      expect(parsed.interval, 1800);
      expect(parsed.leechers, 3);
      expect(parsed.seeders, 10);
      expect(parsed.peers, [Peer(ip: '1.2.3.4', port: 6881), Peer(ip: '5.6.7.8', port: 80)]);
      expect(() => parseUdpAnnounceResponse(res, transactionId: 1), throwsA(isA<TrackerException>()));
    });

    test('UDP error responses surface the message', () {
      final res = Uint8List.fromList([0, 0, 0, 3, 0, 0, 0, 7, ...'torrent not registered'.codeUnits]);
      expect(
        () => parseUdpAnnounceResponse(res, transactionId: 7),
        throwsA(predicate((e) => e.toString().contains('not registered'))),
      );
    });

    test('HTTP responses: compact peers, dict peers, failures', () {
      final compact = parseHttpAnnounceResponse(bencode({
        'interval': 900,
        'complete': 4,
        'peers': Uint8List.fromList([127, 0, 0, 1, 0x1a, 0xe1]),
      }));
      expect(compact.interval, 900);
      expect(compact.seeders, 4);
      expect(compact.peers.single.toString(), '127.0.0.1:6881');

      final dict = parseHttpAnnounceResponse(bencode({
        'interval': 900,
        'peers': [
          {'ip': '10.0.0.1', 'port': 51413}
        ],
      }));
      expect(dict.peers.single, Peer(ip: '10.0.0.1', port: 51413));

      expect(() => parseHttpAnnounceResponse(bencode({'failure reason': 'nope'})), throwsA(isA<TrackerException>()));
    });

    test('HTTP announce URL keeps existing query (passkeys)', () {
      final uri = buildHttpConnectionRequest(
        trackerUrl: 'https://t.example/announce?passkey=abc',
        torrent: torrent,
        params: const AnnounceParams(downloaded: 0, uploaded: 0, left: 5000),
      );
      expect(uri.scheme, 'https');
      expect(uri.query, startsWith('passkey=abc&info_hash='));
      // Uri may un-escape unreserved bytes; the decoded bytes must still match.
      final raw = uri.query.split('&').firstWhere((p) => p.startsWith('info_hash=')).substring(10);
      expect(percentDecodeBytes(raw), torrent.infoHash);
      expect(uri.query, contains('left=5000'));
    });
  });

  group('peer messages', () {
    test('bitfield frame has correct length prefix', () {
      final msg = Messages.buildBitField(Uint8List.fromList([0xff, 0x80]));
      expect(msg, [0, 0, 0, 3, 5, 0xff, 0x80]);
    });

    test('payload-less messages parse (choke/unchoke)', () {
      expect(Messages.parseMessage(Messages.buildUnchoke()).id, MessageId.unchoke);
      expect(Messages.parseMessage(Messages.buildKeepAlive()).id, MessageId.keepAlive);
    });

    test('piece/have/request round trip', () {
      final block = randomBytes(100);
      final (i, b, data) = Messages.parseMessage(Messages.buildPiece(3, 16384, block)).pieceFields;
      expect([i, b], [3, 16384]);
      expect(data, block);
      expect(Messages.parseMessage(Messages.buildHave(77)).haveIndex, 77);
      expect(Messages.parseMessage(Messages.buildRequest(1, 2, 3)).requestFields, (1, 2, 3));
    });

    test('handshake', () {
      final hash = randomBytes(20);
      final hs = Handshake.parse(Messages.buildHandShake(hash, TorrentiaUtils.generateId()))!;
      expect(hs.infoHash, hash);
      expect(String.fromCharCodes(hs.peerId.sublist(0, 8)), '-TT0001-');
    });
  });

  test('Bitfield ignores spare bits and counts', () {
    final bf = Bitfield.fromBytes(Uint8List.fromList([0xff, 0xff]), 10);
    expect(bf.count, 10);
    expect(bf.isComplete, isTrue);
    bf.set(3, false);
    expect(bf[3], isFalse);
    expect(bf.count, 9);
  });

  test('parseRange', () {
    expect(parseRange('bytes=0-', 100), (0, 99));
    expect(parseRange('bytes=10-19', 100), (10, 19));
    expect(parseRange('bytes=-10', 100), (90, 99));
    expect(parseRange('bytes=50-500', 100), (50, 99));
    expect(parseRange('bytes=100-', 100), isNull);
    expect(parseRange('items=0-1', 100), isNull);
  });

  group('Storage and PieceManager', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('torrentia_test'));
    tearDown(() async => dir.delete(recursive: true));

    test('writes pieces across file boundaries in any order', () async {
      final a = randomBytes(1000, 1);
      final b = randomBytes(3000, 2);
      final t = Reader().parse(makeTorrent('pack', {'a.bin': a, 'b.bin': b}, 1024));
      final storage = Storage(t, dir.path, cacheBytes: 0);
      final all = Uint8List.fromList([...a, ...b]);
      for (final p in [3, 0, 2, 1]) {
        await storage.writePiece(p, all.sublist(p * 1024, min((p + 1) * 1024, all.length)));
      }
      expect(await storage.read(900, 300), all.sublist(900, 1200));
      await storage.close();
      expect(await File('${dir.path}/pack/a.bin').readAsBytes(), a);
      expect(await File('${dir.path}/pack/b.bin').readAsBytes(), b);

      final again = Storage(t, dir.path);
      expect(await again.verifyExisting(), [0, 1, 2, 3]);
      await again.close();
    });

    test('picks blocks near the stream cursor first and verifies hashes', () async {
      final data = randomBytes(64 * 1024 * 20);
      final t = Reader().parse(makeTorrent('v.mp4', {'x': data}, 64 * 1024, single: true));
      final storage = Storage(t, dir.path);
      final m = PieceManager(t, storage, readaheadBytes: 128 * 1024, urgentBytes: 64 * 1024);
      final src = _FakeSource();

      final cursor = m.openCursor(12 * 64 * 1024 + 5);
      final picks = m.pickBlocks(src, null, 6);
      expect(picks.map((r) => r.piece).toSet(), {12, 13});
      cursor.close();

      // Deliver piece 12 with one corrupted block: must be rejected.
      final piece12 = data.sublist(12 * 65536, 13 * 65536);
      final reqs = m.pickBlocks(src, null, 100).where((r) => r.piece == 12).toList();
      expect(reqs, isEmpty, reason: 'already requested by this source');
      m.releaseRequests(src);
      final all12 = m.pickBlocks(src, null, 4).where((r) => r.piece == 12).toList();
      expect(all12.length, 4);
      for (final r in all12) {
        final block = Uint8List.fromList(piece12.sublist(r.begin, r.begin + r.length));
        if (r.begin == 0) block[0] ^= 1;
        m.onBlock(src, 12, r.begin, block);
      }
      await Future<void>.delayed(Duration.zero);
      expect(m.have[12], isFalse);
      expect(m.hashFailures, 1);

      final retry = m.pickBlocks(src, null, 4).where((r) => r.piece == 12).toList();
      for (final r in retry) {
        m.onBlock(src, 12, r.begin, piece12.sublist(r.begin, r.begin + r.length));
      }
      await m.waitForPiece(12).timeout(const Duration(seconds: 2));
      expect(await storage.read(12 * 65536, 65536), piece12);
      await storage.close();
    });

    test('rarest-first picks the least available piece; streaming goes in order', () {
      final t = Reader().parse(makeTorrent('d', {'x': randomBytes(16384 * 10)}, 16384, single: true));
      PieceManager setup(PieceStrategy strategy) {
        final m = PieceManager(t, Storage(t, dir.path), strategy: strategy);
        m.markHave([0, 1, 2, 3]); // past the random-first phase
        final allBut7 = Bitfield.full(10)..set(7, false);
        for (var i = 0; i < 3; i++) {
          m.addAvailability(allBut7);
        }
        m.addAvailability(Bitfield(10)..set(7)); // piece 7 has one owner
        return m;
      }

      final peer = Bitfield.full(10);
      expect(setup(PieceStrategy.rarestFirst).pickBlocks(_FakeSource(), peer, 1).single.piece, 7);
      expect(setup(PieceStrategy.streaming).pickBlocks(_FakeSource(), peer, 1).single.piece, 4);
    });

    test('cancels duplicate requests when a block arrives', () {
      final t = Reader().parse(makeTorrent('v', {'x': randomBytes(16384)}, 16384, single: true));
      final m = PieceManager(t, Storage(t, dir.path), requestTimeout: Duration.zero);
      final slow = _FakeSource();
      final fast = _FakeSource();
      final r1 = m.pickBlocks(slow, null, 1).single;
      final r2 = m.pickBlocks(fast, null, 1).single;
      expect(r2, r1, reason: 'stale request gets reassigned');
      m.onBlock(fast, r1.piece, r1.begin, Uint8List(r1.length));
      expect(slow.cancelled, [r1]);
    });
  });

  group('security', () {
    test('public vs private addresses', () {
      bool pub(String ip) => isPublicAddress(InternetAddress(ip));
      for (final ip in ['8.8.8.8', '1.1.1.1', '2606:4700::1111']) {
        expect(pub(ip), isTrue, reason: ip);
      }
      for (final ip in [
        '127.0.0.1', '10.1.2.3', '172.16.0.1', '172.31.255.1', '192.168.1.1', '169.254.1.1',
        '100.64.0.1', '0.0.0.0', '224.0.0.1', '255.255.255.255', '::1', '::', 'fe80::1', 'fd00::1',
        'ff02::1', '::ffff:192.168.1.1',
      ]) {
        expect(pub(ip), isFalse, reason: ip);
      }
    });

    test('malicious torrents are rejected with FormatException', () {
      Uint8List torrent(Map<String, dynamic> info) => bencode({'info': info});
      final hash = Uint8List(20);
      expect(() => Reader().parse(torrent({'name': 'x', 'piece length': 1 << 30, 'length': 1, 'pieces': hash})),
          throwsFormatException, reason: 'huge piece length');
      expect(() => Reader().parse(torrent({'name': 'x', 'piece length': 16384, 'length': -5, 'pieces': hash})),
          throwsFormatException, reason: 'negative length');
      expect(
          () => Reader().parse(torrent({
                'name': 'x',
                'piece length': 16384,
                'pieces': hash,
                'files': [
                  {'length': 'oops', 'path': ['a']}
                ],
              })),
          throwsFormatException,
          reason: 'wrong types');
      expect(() => Reader().parse(Uint8List.fromList('garbage'.codeUnits)), throwsFormatException);
    });

    test('file names are made safe and unique', () {
      final t = Reader().parse(makeTorrent('pack', {
        'CON.txt': randomBytes(1),
        'dir./nul': randomBytes(1),
        'Movie.mkv': randomBytes(1),
        'movie.MKV': randomBytes(1),
        'a/../../b': randomBytes(1),
      }, 16));
      final paths = t.info.files.map((f) => f.path).toList();
      expect(paths[0], 'pack/_CON.txt');
      expect(paths[1], 'pack/dir/_nul');
      expect(paths[3], 'pack/movie (2).MKV');
      expect(t.info.files[4].pathSegments, isNot(contains('..')));
      expect(paths.map((p) => p.toLowerCase()).toSet().length, paths.length);
    });

    test('a source that sent a whole corrupt piece is reported as sole contributor', () async {
      final dir = await Directory.systemTemp.createTemp('torrentia_sec');
      try {
        final t = Reader().parse(makeTorrent('v', {'x': randomBytes(16384 * 2)}, 16384 * 2, single: true));
        final m = PieceManager(t, Storage(t, dir.path));
        final bad = _FakeSource();
        for (final r in m.pickBlocks(bad, null, 10)) {
          m.onBlock(bad, r.piece, r.begin, Uint8List(r.length));
        }
        await Future<void>.delayed(Duration.zero);
        expect(bad.hashFailures, [(0, true)]);
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('web seeds pointing at private networks are refused', () async {
      final t = Reader().parse(makeTorrent('v', {'x': randomBytes(100)}, 16384, single: true));
      final m = PieceManager(t, Storage(t, Directory.systemTemp.path));
      expect(await WebSeed('http://192.168.1.1/x', t, m, m.storage).start(), isFalse);
      expect(await WebSeed('file:///etc/passwd', t, m, m.storage).start(), isFalse);
    });

    test('stream server: token required, no CORS, host checked, names escaped', () async {
      final t = Reader().parse(makeTorrent('v', {"x'-alert(1)-'<b>.mp4": randomBytes(100)}, 16384));
      final dir = await Directory.systemTemp.createTemp('torrentia_srv');
      final session = TorrentSession(t, SessionOptions(outputDir: dir.path, useTrackers: false, listenPort: 0));
      final server = StreamServer(session, port: 0);
      await server.start();
      final client = HttpClient();
      Future<HttpClientResponse> get(String url, {String? host}) async {
        final req = await client.getUrl(Uri.parse(url));
        if (host != null) req.headers.host = host;
        return req.close();
      }

      try {
        final root = 'http://127.0.0.1:${server.boundPort}';
        expect((await get('$root/status')).statusCode, 404, reason: 'no token');
        expect((await get('$root/${'0' * 32}/status')).statusCode, 404, reason: 'wrong token');
        expect((await get('${server.baseUrl}/status', host: 'evil.example')).statusCode, 403, reason: 'rebinding');

        final ok = await get('${server.baseUrl}/status');
        expect(ok.statusCode, 200);
        expect(ok.headers.value('access-control-allow-origin'), isNull);

        final index = await get('${server.baseUrl}/');
        final html = await index.transform(const SystemEncoding().decoder).join();
        expect(index.headers.value('content-security-policy'), contains("script-src 'nonce-"));
        expect(html, isNot(contains('onclick')));
        expect(html, isNot(contains('<b>')));
        expect(html, contains('data-src='));
      } finally {
        client.close();
        await server.close();
        await session.close();
        await dir.delete(recursive: true);
      }
    });
  });

  test('end to end: seeder -> leecher over TCP, streamed over HTTP', () async {
    final root = await Directory.systemTemp.createTemp('torrentia_e2e');
    try {
      final subs = randomBytes(5000, 3);
      final video = randomBytes(1500 * 1024 + 123, 4);
      final bytes = makeTorrent('Show', {'subs.srt': subs, 'video.mp4': video}, 32 * 1024);
      final torrent = Reader().parse(bytes);

      final seedDir = Directory('${root.path}/seed');
      await File('${seedDir.path}/Show/subs.srt').create(recursive: true).then((f) => f.writeAsBytes(subs));
      await File('${seedDir.path}/Show/video.mp4').writeAsBytes(video);

      const opts = (trackers: false, webSeeds: false, port: 0);
      final seeder = TorrentSession(
        torrent,
        SessionOptions(outputDir: seedDir.path, listenPort: opts.port, useTrackers: opts.trackers, useWebSeeds: opts.webSeeds),
      );
      final leecher = TorrentSession(
        torrent,
        SessionOptions(outputDir: '${root.path}/leech', listenPort: opts.port, useTrackers: opts.trackers, useWebSeeds: opts.webSeeds),
      );
      await seeder.start();
      expect(seeder.manager.isComplete, isTrue);
      await leecher.start();

      final server = StreamServer(leecher, port: 0);
      await server.start();
      leecher.addPeers([Peer(ip: '127.0.0.1', port: seeder.listenPort)]);

      // Stream a range from the middle of the video while it downloads.
      final client = HttpClient();
      final req = await client.getUrl(Uri.parse(server.streamUrl(1)));
      req.headers.set('Range', 'bytes=700000-899999');
      final res = await req.close();
      expect(res.statusCode, 206);
      expect(res.headers.value('content-range'), 'bytes 700000-899999/${video.length}');
      final body = await res.fold<BytesBuilder>(BytesBuilder(), (b, d) => b..add(d));
      expect(body.toBytes(), video.sublist(700000, 900000));
      client.close();

      await leecher.whenComplete.timeout(const Duration(seconds: 30));
      await server.close();
      await leecher.close();
      await seeder.close();
      expect(await File('${root.path}/leech/Show/video.mp4').readAsBytes(), video);
      expect(await File('${root.path}/leech/Show/subs.srt').readAsBytes(), subs);
    } finally {
      await root.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(seconds: 60)));
}
