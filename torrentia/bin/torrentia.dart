import 'dart:async';
import 'dart:io';

import 'package:torrentia/torrentia.dart';

const _usage = '''
Usage: dart run bin/torrentia.dart <file.torrent> [options]

Stream mode (default): serves a video over HTTP while it downloads.
Open the printed URL in VLC/mpv (or the browser page) to watch.

Download mode (--download): fetches the whole torrent (or -f file) as fast
as possible using rarest-first piece selection, then exits (or seeds).

Options:
  -f, --file <index>      File to stream/download (default: stream the largest
                          video file; download everything)
  -o, --output <dir>      Download directory (default: downloads)
  -p, --http-port <port>  Stream server port (default: 8888)
      --peer-port <port>  Port to accept peers on (default: 6881)
      --max-peers <n>     Max peer connections (default: 60)
      --download          Download mode: no stream server, exit when done
      --seed              With --download: keep seeding after completion
      --all               Stream mode: also download the other files
      --list              List files and exit
      --no-webseeds       Ignore HTTP web seeds
  -v, --verbose           Debug logging
  -h, --help              Show this help
''';

Future<void> main(List<String> args) async {
  String? torrentPath;
  int? fileIndex;
  var outputDir = 'downloads';
  var httpPort = 8888;
  var peerPort = 6881;
  var maxPeers = 60;
  var downloadOnly = false;
  var seed = false;
  var all = false;
  var list = false;
  var webSeeds = true;

  try {
    for (var i = 0; i < args.length; i++) {
      final a = args[i];
      String value() {
        if (i + 1 >= args.length) throw FormatException('Missing value for $a');
        return args[++i];
      }

      switch (a) {
        case '-f' || '--file':
          fileIndex = int.parse(value());
        case '-o' || '--output':
          outputDir = value();
        case '-p' || '--http-port':
          httpPort = int.parse(value());
        case '--peer-port':
          peerPort = int.parse(value());
        case '--max-peers':
          maxPeers = int.parse(value());
        case '--download':
          downloadOnly = true;
        case '--seed':
          seed = true;
        case '--all':
          all = true;
        case '--list':
          list = true;
        case '--no-webseeds':
          webSeeds = false;
        case '-v' || '--verbose':
          Log.level = LogLevel.debug;
        case '-h' || '--help':
          stdout.write(_usage);
          return;
        default:
          if (a.startsWith('-') || torrentPath != null) throw FormatException('Unknown argument: $a');
          torrentPath = a;
      }
    }
    if (torrentPath == null) throw const FormatException('No torrent file given');
  } on FormatException catch (e) {
    stderr.writeln('${e.message}\n');
    stderr.write(_usage);
    exitCode = 64;
    return;
  }

  final session = await TorrentSession.load(
    torrentPath,
    SessionOptions(
      outputDir: outputDir,
      listenPort: peerPort,
      maxPeers: maxPeers,
      useWebSeeds: webSeeds,
      strategy: downloadOnly ? PieceStrategy.rarestFirst : PieceStrategy.streaming,
    ),
  );
  final files = session.torrent.info.files;

  if (list) {
    for (var i = 0; i < files.length; i++) {
      stdout.writeln('[$i] ${files[i].path} (${TorrentiaUtils.formatBytes(files[i].size)})');
    }
    return;
  }

  final selected = fileIndex ?? session.defaultFileIndex;
  if (selected < 0 || selected >= files.length) {
    stderr.writeln('File index $selected out of range (0-${files.length - 1})');
    exitCode = 64;
    return;
  }
  // Download mode takes everything unless a file was named; stream mode takes
  // the streamed file unless --all.
  if (downloadOnly ? fileIndex != null : !all) session.selectFile(selected);

  Log.info('${session.torrent.info.name} (${TorrentiaUtils.formatBytes(session.torrent.size)}, '
      '${session.torrent.info.pieceCount} pieces, info hash ${session.torrent.infoHashHex})');
  await session.start();

  StreamServer? server;
  if (!downloadOnly) {
    server = StreamServer(session, port: httpPort);
    await server.start();
    stdout.writeln('\nStreaming ${files[selected].path}');
    stdout.writeln('  Player URL: ${server.streamUrl(selected)}');
    stdout.writeln('  Web page:   ${server.baseUrl}/\n');
  }

  var stopping = false;
  Future<void> shutdown() async {
    if (stopping) return;
    stopping = true;
    stdout.writeln('\nShutting down...');
    await server?.close();
    await session.close();
    exit(0);
  }

  ProcessSignal.sigint.watch().listen((_) => shutdown());

  final status = Timer.periodic(const Duration(seconds: 2), (_) => Log.info(session.statusLine()));

  if (downloadOnly) {
    final started = DateTime.now();
    await session.whenComplete;
    final secs = DateTime.now().difference(started).inMilliseconds / 1000;
    final bytes = session.manager.receivedBytes; // this run only, not resumed data
    Log.info('Done in ${secs.toStringAsFixed(1)} s '
        '(avg ${TorrentiaUtils.formatBytes(bytes / (secs > 0 ? secs : 1))}/s). '
        'Saved to ${Directory(outputDir).absolute.path}');
    if (seed) {
      Log.info('Seeding. Press Ctrl+C to stop.');
      return;
    }
    status.cancel();
    await shutdown();
  }
}
