<?php
use Ratchet\Server\IoServer;
use Ratchet\Http\HttpServer;
use Ratchet\WebSocket\WsServer;
use React\Socket\SocketServer;
use React\EventLoop\Factory;
use MyApp\SshTerminal;

require __DIR__ . '/vendor/autoload.php';

// ✅ Ensure SSH2 exists
if (!extension_loaded('ssh2')) {
    die("❌ SSH2 extension not loaded\n");
}

$port = 9090;
$host = "127.0.0.1"; // ✅ INTERNAL ONLY

$app = new SshTerminal();

$loop = Factory::create();

// ✅ Bind to INTERNAL IP ONLY
$socket = new SocketServer("$host:$port", [], $loop);

$server = new IoServer(
    new HttpServer(
        new WsServer($app)
    ),
    $socket,
    $loop
);

echo "✅ Internal WebSocket SSH Server Running on $host:$port\n";
$loop->run();
