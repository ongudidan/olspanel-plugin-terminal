<?php
namespace MyApp;

use Ratchet\MessageComponentInterface;
use Ratchet\ConnectionInterface;
use React\EventLoop\Loop;

class SshTerminal implements MessageComponentInterface {

    protected $clients;
    protected $ssh_connections;

    public function __construct() {
        $this->clients = new \SplObjectStorage;
        $this->ssh_connections = [];
    }

  public function onOpen(ConnectionInterface $conn) {

    $this->clients->attach($conn);

    // ===== READ QUERY PARAMS =====
    $req = $conn->httpRequest;
    parse_str($req->getUri()->getQuery(), $params);

    $clientToken = isset($params['token']) && is_string($params['token']) ? $params['token'] : null;

    // ===== LOAD ENV (STATIC CONFIG) =====
    $token = getenv('TERMINAL_TOKEN');
    $host  = getenv('TERMINAL_HOST') ?: '127.0.0.1';
    $user  = getenv('TERMINAL_USER');
    $pass  = getenv('TERMINAL_PASS');
	$port  = getenv('TERMINAL_PORT') ?: '22';

    // ===== VALIDATION =====
    if (!is_string($clientToken) || !is_string($token) || !$user || !$pass) {
        $conn->send(json_encode([
            'type' => 'error',
            'data' => 'Missing terminal credentials'
        ]));
        $conn->close();
        return;
    }

    if (!hash_equals($token, $clientToken)) {
        $conn->send(json_encode([
            'type' => 'error',
            'data' => 'Invalid terminal token'
        ]));
        $conn->close();
        return;
    }

    // ===== INIT CONNECTION STORAGE =====
    $this->ssh_connections[$conn->resourceId] = [
        'ssh_conn'     => null,
        'shell_stream' => null,
    ];

    try {

        // ===== SSH CONNECT =====
        $ssh = ssh2_connect($host, $port);
        if (!$ssh) {
            throw new \Exception("SSH connection failed");
        }

        if (!ssh2_auth_password($ssh, $user, $pass)) {
            throw new \Exception("SSH authentication failed");
        }

        // ===== OPEN SHELL =====
        $shell = ssh2_shell($ssh, 'xterm', null, 120, 40, SSH2_TERM_UNIT_CHARS);
        if (!$shell) {
            throw new \Exception("Failed to open SSH shell");
        }

        stream_set_blocking($shell, false);

        $this->ssh_connections[$conn->resourceId]['ssh_conn']     = $ssh;
        $this->ssh_connections[$conn->resourceId]['shell_stream'] = $shell;

        // ===== AUTO ROOT SWITCH =====
        if ($user === 'olsadmin') {
            usleep(200000);
            fwrite($shell, "sudo -i\n");

            // ===== CLEAR TERMINAL =====
            usleep(200000);
            fwrite($shell, "clear\n");

            // ===== NOTIFY CLIENT =====
            $conn->send(json_encode([
                'type' => 'info',
                'data' => "Connected as root@$host"
            ]));
        } else {
            // ===== NOTIFY CLIENT =====
            $conn->send(json_encode([
                'type' => 'info',
                'data' => "Connected as $user@$host"
            ]));
        }

        $this->startStreamReading($conn);

    } catch (\Exception $e) {

        $conn->send(json_encode([
            'type' => 'error',
            'data' => 'SSH Error: ' . $e->getMessage()
        ]));

        $conn->close();
    }
}
  
    public function onMessage(ConnectionInterface $from, $msg) {
        $data = json_decode($msg, true);
        $conn_data = $this->ssh_connections[$from->resourceId] ?? null;

        if (!$conn_data || !$conn_data['shell_stream']) {
            return;
        }

        // ===== INPUT FROM CLIENT =====
        if (isset($data['input'])) {
            fwrite($conn_data['shell_stream'], $data['input']);
        }

        // ===== RESIZE =====
        if (isset($data['cols'], $data['rows'])) {
            ssh2_shell_resize(
                $conn_data['shell_stream'],
                (int)$data['cols'],
                (int)$data['rows']
            );
        }
    }

    public function onClose(ConnectionInterface $conn) {
        $this->cleanup($conn);
    }

    public function onError(ConnectionInterface $conn, \Exception $e) {
        $conn->send(json_encode([
            'type' => 'error',
            'data' => 'Internal error'
        ]));
        $this->cleanup($conn);
    }

    protected function startStreamReading(ConnectionInterface $conn) {
        $stream = $this->ssh_connections[$conn->resourceId]['shell_stream'];
        $loop = Loop::get();

        $loop->addReadStream($stream, function ($stream) use ($conn) {
            $output = fread($stream, 8192);

            if ($output === '' || $output === false) {
                $this->cleanup($conn);
                return;
            }

            $conn->send(json_encode([
                'type' => 'output',
                'data' => $output
            ]));
        });
    }

    protected function cleanup(ConnectionInterface $conn) {
        if (!isset($this->ssh_connections[$conn->resourceId])) {
            return;
        }

        $data = $this->ssh_connections[$conn->resourceId];
        $loop = Loop::get();

        if (!empty($data['shell_stream'])) {
            $loop->removeReadStream($data['shell_stream']);
            fclose($data['shell_stream']);
        }

        unset($this->ssh_connections[$conn->resourceId]);
        $this->clients->detach($conn);
    }
}
