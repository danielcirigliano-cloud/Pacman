#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Pac-Man Mundialista ONLINE FIN-07
Servidor HTTP + WebSocket sin dependencias externas.
- Sirve index.html e imagenes/audio desde la carpeta del juego.
- Salas de hasta 4 jugadores.
- El primer jugador de cada sala es HOST y simula la partida.
- El servidor retransmite inputs y snapshots autoritativos.
"""

import argparse
import base64
import hashlib
import json
import os
import random
import socket
import struct
import threading
import time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
ROOM_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

rooms = {}
rooms_lock = threading.RLock()


class WSClient:
    def __init__(self, handler):
        self.handler = handler
        self.sock = handler.connection
        self.id = f"p_{random.getrandbits(48):012x}"
        self.room_code = None
        self.name = "Jugador"
        self.avatar = "2.jpg"
        self.send_lock = threading.Lock()
        self.connected = True

    def send_json(self, payload):
        if not self.connected:
            return
        raw = json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
        frame = encode_ws_frame(raw, opcode=0x1)
        try:
            with self.send_lock:
                self.sock.sendall(frame)
        except Exception:
            self.connected = False

    def close(self):
        self.connected = False
        try:
            with self.send_lock:
                self.sock.sendall(encode_ws_frame(b"", opcode=0x8))
        except Exception:
            pass
        try:
            self.sock.shutdown(socket.SHUT_RDWR)
        except Exception:
            pass
        try:
            self.sock.close()
        except Exception:
            pass


def encode_ws_frame(payload: bytes, opcode=0x1):
    fin_opcode = 0x80 | (opcode & 0x0F)
    n = len(payload)
    if n < 126:
        return bytes([fin_opcode, n]) + payload
    if n <= 0xFFFF:
        return bytes([fin_opcode, 126]) + struct.pack("!H", n) + payload
    return bytes([fin_opcode, 127]) + struct.pack("!Q", n) + payload


def recv_exact(sock, n):
    data = bytearray()
    while len(data) < n:
        chunk = sock.recv(n - len(data))
        if not chunk:
            raise ConnectionError("socket closed")
        data.extend(chunk)
    return bytes(data)


def read_ws_frame(sock):
    header = recv_exact(sock, 2)
    b1, b2 = header
    opcode = b1 & 0x0F
    masked = bool(b2 & 0x80)
    length = b2 & 0x7F

    if length == 126:
        length = struct.unpack("!H", recv_exact(sock, 2))[0]
    elif length == 127:
        length = struct.unpack("!Q", recv_exact(sock, 8))[0]

    mask = recv_exact(sock, 4) if masked else None
    payload = recv_exact(sock, length) if length else b""

    if masked and payload:
        payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))

    return opcode, payload


def new_room_code():
    with rooms_lock:
        while True:
            code = "".join(random.choice(ROOM_ALPHABET) for _ in range(5))
            if code not in rooms:
                return code


def public_lobby(room):
    return {
        "room": room["code"],
        "host_id": room["host_id"],
        "started": room["started"],
        "scenario": room["scenario"],
        "ghost_avatar": room["ghost_avatar"],
        "players": [
            {"id": c.id, "name": c.name, "avatar": c.avatar}
            for c in room["clients"].values()
            if c.connected
        ],
    }


def broadcast(room, payload, exclude=None):
    clients = list(room["clients"].values())
    for c in clients:
        if c.connected and c.id != exclude:
            c.send_json(payload)


def send_lobby(room):
    broadcast(room, {"type": "lobby_state", "lobby": public_lobby(room)})


def remove_client(client):
    with rooms_lock:
        code = client.room_code
        if not code or code not in rooms:
            return

        room = rooms[code]
        room["clients"].pop(client.id, None)

        if not room["clients"]:
            rooms.pop(code, None)
            return

        if room["host_id"] == client.id:
            next_host = next(iter(room["clients"].values()))
            room["host_id"] = next_host.id
            next_host.send_json({
                "type": "host_changed",
                "host_id": next_host.id,
                "last_state": room.get("last_state"),
                "lobby": public_lobby(room),
            })

        send_lobby(room)
        broadcast(room, {"type": "player_disconnected", "player_id": client.id})


def handle_message(client, msg):
    kind = msg.get("type")

    if kind == "create_room":
        with rooms_lock:
            if client.room_code:
                remove_client(client)

            code = new_room_code()
            client.name = str(msg.get("name") or "Jugador")[:24]
            client.avatar = str(msg.get("avatar") or "2.jpg")
            client.room_code = code

            room = {
                "code": code,
                "host_id": client.id,
                "clients": {client.id: client},
                "started": False,
                "scenario": str(msg.get("scenario") or "rotation"),
                "ghost_avatar": str(msg.get("ghost_avatar") or "1.jpg"),
                "last_state": None,
            }
            rooms[code] = room

        client.send_json({
            "type": "room_created",
            "player_id": client.id,
            "lobby": public_lobby(room),
        })
        send_lobby(room)
        return

    if kind == "join_room":
        code = str(msg.get("room") or "").strip().upper()
        with rooms_lock:
            room = rooms.get(code)
            if not room:
                client.send_json({"type": "error", "message": "Sala inexistente."})
                return
            if room["started"]:
                client.send_json({"type": "error", "message": "La partida ya comenzó."})
                return
            if len(room["clients"]) >= 4:
                client.send_json({"type": "error", "message": "La sala ya tiene 4 jugadores."})
                return

            client.name = str(msg.get("name") or "Jugador")[:24]
            client.avatar = str(msg.get("avatar") or "2.jpg")
            client.room_code = code
            room["clients"][client.id] = client

        client.send_json({
            "type": "room_joined",
            "player_id": client.id,
            "lobby": public_lobby(room),
        })
        send_lobby(room)
        return

    code = client.room_code
    with rooms_lock:
        room = rooms.get(code) if code else None

    if not room:
        client.send_json({"type": "error", "message": "No estás dentro de una sala."})
        return

    if kind == "update_profile":
        client.name = str(msg.get("name") or client.name)[:24]
        client.avatar = str(msg.get("avatar") or client.avatar)
        send_lobby(room)
        return

    if kind == "lobby_config":
        if room["host_id"] != client.id:
            return
        room["scenario"] = str(msg.get("scenario") or room["scenario"])
        room["ghost_avatar"] = str(msg.get("ghost_avatar") or room["ghost_avatar"])
        send_lobby(room)
        return

    if kind == "start_game":
        if room["host_id"] != client.id:
            return
        room["started"] = True
        room["last_state"] = None
        broadcast(room, {
            "type": "start_game",
            "lobby": public_lobby(room),
            "server_time": time.time(),
        })
        return

    if kind == "input":
        host = room["clients"].get(room["host_id"])
        if host and host.connected:
            host.send_json({
                "type": "remote_input",
                "player_id": client.id,
                "dx": int(msg.get("dx") or 0),
                "dy": int(msg.get("dy") or 0),
            })
        return

    if kind == "continue_vote":
        host = room["clients"].get(room["host_id"])
        if host and host.connected:
            host.send_json({
                "type": "continue_vote",
                "player_id": client.id,
            })
        broadcast(room, {
            "type": "continue_vote_notice",
            "player_id": client.id,
        })
        return

    if kind == "host_state":
        if room["host_id"] != client.id:
            return
        state = msg.get("state")
        room["last_state"] = state
        broadcast(room, {"type": "state", "state": state}, exclude=client.id)
        return

    if kind == "game_end":
        if room["host_id"] != client.id:
            return
        room["started"] = False
        room["last_state"] = None
        broadcast(room, {"type": "game_end", "reason": msg.get("reason", "")})
        send_lobby(room)
        return


class Handler(SimpleHTTPRequestHandler):
    server_version = "PacManOnline/FIN07"

    def do_GET(self):
        parsed = urlparse(self.path)

        if parsed.path == "/api/status":
            with rooms_lock:
                info = {
                    "status": "ok",
                    "build": "FIN-07 ONLINE",
                    "rooms": len(rooms),
                    "players": sum(len(r["clients"]) for r in rooms.values()),
                    "max_players_per_room": 4,
                }
            raw = json.dumps(info).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(raw)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(raw)
            return

        if parsed.path == "/ws" and self.headers.get("Upgrade", "").lower() == "websocket":
            self.handle_websocket()
            return

        return super().do_GET()

    def end_headers(self):
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate")
        self.send_header("Pragma", "no-cache")
        super().end_headers()

    def handle_websocket(self):
        key = self.headers.get("Sec-WebSocket-Key")
        if not key:
            self.send_error(400)
            return

        accept = base64.b64encode(
            hashlib.sha1((key + WS_GUID).encode("ascii")).digest()
        ).decode("ascii")

        self.send_response(101, "Switching Protocols")
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        self.end_headers()
        self.wfile.flush()

        client = WSClient(self)
        client.send_json({"type": "hello", "connection_id": client.id})

        try:
            while client.connected:
                opcode, payload = read_ws_frame(self.connection)

                if opcode == 0x8:
                    break
                if opcode == 0x9:
                    with client.send_lock:
                        client.sock.sendall(encode_ws_frame(payload, opcode=0xA))
                    continue
                if opcode != 0x1:
                    continue

                try:
                    msg = json.loads(payload.decode("utf-8"))
                except Exception:
                    continue

                try:
                    handle_message(client, msg)
                except Exception as exc:
                    client.send_json({"type": "error", "message": f"Error de servidor: {exc}"})
        except Exception:
            pass
        finally:
            client.connected = False
            remove_client(client)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8095)
    parser.add_argument("--root", default=os.getcwd())
    args = parser.parse_args()

    root = os.path.abspath(args.root)
    os.chdir(root)

    def factory(*a, **kw):
        return Handler(*a, directory=root, **kw)

    server = ThreadingHTTPServer(("0.0.0.0", args.port), factory)
    server.daemon_threads = True

    print("=" * 64)
    print(" PAC-MAN MUNDIALISTA - ONLINE FIN-07")
    print("=" * 64)
    print(f" Carpeta: {root}")
    print(f" Puerto : {args.port}")
    print(f" Local  : http://127.0.0.1:{args.port}/")
    print(" WebSocket: /ws")
    print(" CTRL+C para detener.")
    print("=" * 64)

    try:
        server.serve_forever(poll_interval=0.2)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
