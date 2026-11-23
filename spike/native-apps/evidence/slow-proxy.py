"""A TCP proxy that waits before it passes each connection on: in front of the app's server for the
evidence run (run.sh), so the phone's <Loading> fallback is on screen while a GET is on its way.

    python3 -I slow-proxy.py 8096 8095 2.5    # listen on 8096, forward to 127.0.0.1:8095 after 2.5 s
"""
import socket
import sys
import threading
import time

listen, upstream, delay = int(sys.argv[1]), int(sys.argv[2]), float(sys.argv[3])


def pipe(source, sink):
    try:
        while True:
            data = source.recv(65536)
            if not data:
                break
            sink.sendall(data)
    except OSError:
        pass
    finally:
        try:
            sink.shutdown(socket.SHUT_WR)
        except OSError:
            pass


def serve(client):
    time.sleep(delay)
    server = socket.create_connection(("127.0.0.1", upstream))
    threading.Thread(target=pipe, args=(client, server), daemon=True).start()
    pipe(server, client)
    client.close()
    server.close()


listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
listener.bind(("127.0.0.1", listen))
listener.listen(16)
while True:
    connection, _ = listener.accept()
    threading.Thread(target=serve, args=(connection,), daemon=True).start()
