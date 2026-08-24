import socket
import struct
import threading

HOST = "0.0.0.0"
PORT = 1080

USERNAME = "gay"
PASSWORD = "mts_sosal"


def relay(a, b):
    try:
        while True:
            data = a.recv(65536)
            if not data:
                break
            b.sendall(data)
    except:
        pass
    finally:
        try:
            a.close()
        except:
            pass
        try:
            b.close()
        except:
            pass


def handle(client):
    try:
        # SOCKS5 greeting
        header = client.recv(2)

        if len(header) != 2 or header[0] != 5:
            client.close()
            return

        nmethods = header[1]
        methods = client.recv(nmethods)

        # Require username/password authentication
        if 2 not in methods:
            client.sendall(b"\x05\xff")
            client.close()
            return

        client.sendall(b"\x05\x02")

        # Username/password authentication
        auth = client.recv(2)

        if len(auth) != 2 or auth[0] != 1:
            client.close()
            return

        username_len = auth[1]
        username = client.recv(username_len).decode()

        password_len = client.recv(1)[0]
        password = client.recv(password_len).decode()

        if username != USERNAME or password != PASSWORD:
            client.sendall(b"\x01\x01")
            client.close()
            return

        client.sendall(b"\x01\x00")

        # SOCKS5 CONNECT request
        req = client.recv(4)

        if len(req) != 4 or req[0] != 5:
            client.close()
            return

        cmd = req[1]
        atyp = req[3]

        if cmd != 1:
            client.sendall(
                b"\x05\x07\x00\x01\x00\x00\x00\x00\x00\x00"
            )
            client.close()
            return

        if atyp == 1:
            addr = socket.inet_ntoa(client.recv(4))

        elif atyp == 3:
            length = client.recv(1)[0]
            addr = client.recv(length).decode("idna")

        elif atyp == 4:
            addr = socket.inet_ntop(
                socket.AF_INET6,
                client.recv(16)
            )

        else:
            client.close()
            return

        port = struct.unpack("!H", client.recv(2))[0]

        remote = socket.create_connection(
            (addr, port),
            timeout=15
        )

        # Connection successful
        client.sendall(
            b"\x05\x00\x00\x01"
            b"\x00\x00\x00\x00"
            b"\x00\x00"
        )

        threading.Thread(
            target=relay,
            args=(client, remote),
            daemon=True
        ).start()

        threading.Thread(
            target=relay,
            args=(remote, client),
            daemon=True
        ).start()

    except Exception:
        try:
            client.close()
        except:
            pass


server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind((HOST, PORT))
server.listen(50)

print("SOCKS5 server started on 0.0.0.0:1080")
print("Username:", USERNAME)

while True:
    client, address = server.accept()
    print("Connection from:", address)

    threading.Thread(
        target=handle,
        args=(client,),
        daemon=True
    ).start()