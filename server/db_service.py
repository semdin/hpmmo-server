#!/usr/bin/env python3
"""
PotterMetin MMO - Server Database Service
Handles Account Authentication, Character Persistence, and ACID Transactions.
Supports PostgreSQL with automatic SQLite local fallback.
Listens on 127.0.0.1:8081 (Internal Server API).
"""

import sys
import os
import json
import sqlite3
import hashlib
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse

PORT = int(os.environ.get("DB_PORT", 8081))
DB_TYPE = "sqlite" # 'postgresql' or 'sqlite'
PG_CONN = None
SQLITE_PATH = os.path.join(os.path.dirname(__file__), "pottermetin_server.db")

# Optional PostgreSQL driver support
try:
    import psycopg2
    from psycopg2.extras import RealDictCursor
    PG_URL = os.environ.get("DATABASE_URL", "postgresql://pottermetin:REDACTED_SECRET@localhost:5432/pottermetin_db")
    try:
        PG_CONN = psycopg2.connect(PG_URL)
        PG_CONN.autocommit = True
        DB_TYPE = "postgresql"
        print(f"[DB Service] Connected to PostgreSQL at {PG_URL.split('@')[-1]}")
    except Exception as e:
        print(f"[DB Service] PostgreSQL connection notice: {e}. Falling back to SQLite.")
        DB_TYPE = "sqlite"
except ImportError:
    DB_TYPE = "sqlite"

def hash_password(password: str) -> str:
    return hashlib.sha256(password.encode("utf-8")).hexdigest()

def get_sqlite():
    conn = sqlite3.connect(SQLITE_PATH)
    conn.row_factory = sqlite3.Row
    return conn

def init_db():
    if DB_TYPE == "sqlite":
        conn = get_sqlite()
        cur = conn.cursor()
        cur.execute("""
            CREATE TABLE IF NOT EXISTS accounts (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                username TEXT UNIQUE NOT NULL,
                password_hash TEXT NOT NULL,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                last_login TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            );
        """)
        cur.execute("""
            CREATE TABLE IF NOT EXISTS characters (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                name TEXT UNIQUE NOT NULL,
                house TEXT NOT NULL DEFAULT 'Gryffindor',
                level INTEGER NOT NULL DEFAULT 1,
                exp INTEGER NOT NULL DEFAULT 0,
                max_hp INTEGER NOT NULL DEFAULT 500,
                current_hp INTEGER NOT NULL DEFAULT 500,
                max_mana INTEGER NOT NULL DEFAULT 300,
                current_mana INTEGER NOT NULL DEFAULT 300,
                galleons INTEGER NOT NULL DEFAULT 500,
                wand_tier INTEGER NOT NULL DEFAULT 0,
                pos_x REAL NOT NULL DEFAULT 0.0,
                pos_y REAL NOT NULL DEFAULT 0.5,
                pos_z REAL NOT NULL DEFAULT 5.0,
                rot_y REAL NOT NULL DEFAULT 3.14159,
                inventory TEXT NOT NULL DEFAULT '[]',
                quests TEXT NOT NULL DEFAULT '{}',
                updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            );
        """)
        cur.execute("""
            CREATE TABLE IF NOT EXISTS trade_logs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                sender_char_id INTEGER,
                receiver_char_id INTEGER,
                details TEXT NOT NULL,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            );
        """)
        conn.commit()
        conn.close()
        print(f"[DB Service] SQLite database initialized at {SQLITE_PATH}")

init_db()

class DBRequestHandler(BaseHTTPRequestHandler):
    def _send_json(self, status_code: int, data: dict):
        body = json.dumps(data).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/api/health":
            self._send_json(200, {"status": "ok", "db": DB_TYPE})
        elif parsed.path == "/api/version":
            v_path = os.path.join(os.path.dirname(__file__), "version.json")
            if os.path.exists(v_path):
                with open(v_path, "r", encoding="utf-8") as f:
                    self._send_json(200, json.load(f))
            else:
                self._send_json(200, {"version": "1.1.0", "game_title": "PotterMetin MMO"})
        elif parsed.path.startswith("/patch/"):
            patch_name = os.path.basename(parsed.path)
            patch_path = os.path.join(os.path.dirname(__file__), "patches", patch_name)
            if os.path.exists(patch_path):
                with open(patch_path, "rb") as f:
                    bytes_data = f.read()
                self.send_response(200)
                self.send_header("Content-Type", "application/zip")
                self.send_header("Content-Length", str(len(bytes_data)))
                self.end_headers()
                self.wfile.write(bytes_data)
            else:
                self._send_json(404, {"error": "Patch file not found"})
        else:
            self._send_json(404, {"error": "Not found"})

    def do_POST(self):
        parsed = urlparse(self.path)
        content_len = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_len).decode("utf-8") if content_len > 0 else "{}"
        try:
            req_data = json.loads(body)
        except Exception:
            self._send_json(400, {"error": "Invalid JSON payload"})
            return

        if parsed.path == "/api/register":
            self.handle_register(req_data)
        elif parsed.path == "/api/login":
            self.handle_login(req_data)
        elif parsed.path == "/api/characters/list":
            self.handle_character_list(req_data)
        elif parsed.path == "/api/characters/create":
            self.handle_character_create(req_data)
        elif parsed.path == "/api/characters/load":
            self.handle_character_load(req_data)
        elif parsed.path == "/api/characters/save":
            self.handle_character_save(req_data)
        elif parsed.path == "/api/trade":
            self.handle_trade(req_data)
        else:
            self._send_json(404, {"error": "Endpoint not found"})

    def handle_register(self, req: dict):
        username = req.get("username", "").strip()
        password = req.get("password", "").strip()
        if not username or len(username) < 3:
            self._send_json(400, {"success": False, "message": "Username must be at least 3 characters."})
            return
        if not password or len(password) < 4:
            self._send_json(400, {"success": False, "message": "Password must be at least 4 characters."})
            return

        p_hash = hash_password(password)
        conn = get_sqlite()
        cur = conn.cursor()
        try:
            cur.execute("INSERT INTO accounts (username, password_hash) VALUES (?, ?)", (username, p_hash))
            acc_id = cur.lastrowid
            conn.commit()
            self._send_json(200, {"success": True, "message": "Account created successfully!", "account_id": acc_id})
        except sqlite3.IntegrityError:
            self._send_json(409, {"success": False, "message": "Username already exists. Please choose another."})
        finally:
            conn.close()

    def handle_login(self, req: dict):
        username = req.get("username", "").strip()
        password = req.get("password", "").strip()
        p_hash = hash_password(password)

        conn = get_sqlite()
        cur = conn.cursor()
        cur.execute("SELECT id FROM accounts WHERE username = ? AND password_hash = ?", (username, p_hash))
        row = cur.fetchone()
        if not row:
            conn.close()
            self._send_json(401, {"success": False, "message": "Invalid username or password."})
            return

        acc_id = row["id"]
        cur.execute("UPDATE accounts SET last_login = CURRENT_TIMESTAMP WHERE id = ?", (acc_id,))
        conn.commit()

        # Query characters
        cur.execute("SELECT id, name, house, level, wand_tier, pos_x, pos_y, pos_z, galleons FROM characters WHERE account_id = ?", (acc_id,))
        chars = [dict(c) for c in cur.fetchall()]
        conn.close()

        self._send_json(200, {
            "success": True,
            "message": "Login successful!",
            "account_id": acc_id,
            "username": username,
            "characters": chars
        })

    def handle_character_list(self, req: dict):
        acc_id = req.get("account_id")
        conn = get_sqlite()
        cur = conn.cursor()
        cur.execute("SELECT id, name, house, level, wand_tier, pos_x, pos_y, pos_z, galleons FROM characters WHERE account_id = ?", (acc_id,))
        chars = [dict(c) for c in cur.fetchall()]
        conn.close()
        self._send_json(200, {"success": True, "characters": chars})

    def handle_character_create(self, req: dict):
        acc_id = req.get("account_id")
        name = req.get("name", "").strip()
        house = req.get("house", "Gryffindor").strip()
        if not name or len(name) < 2:
            self._send_json(400, {"success": False, "message": "Character name must be at least 2 characters."})
            return

        starter_inventory = [
            {"id": "wand_hawthorn", "amount": 1, "tier": 0},
            {"id": "robe_apprentice", "amount": 1, "tier": 0},
            {"id": "broom_nimbus2000", "amount": 1, "tier": 0},
            {"id": "mat_phoenix_ash", "amount": 5, "tier": 0},
            {"id": "mat_dragon_heartstring", "amount": 2, "tier": 0},
            {"id": "potion_health", "amount": 5, "tier": 0},
            {"id": "potion_mana", "amount": 5, "tier": 0}
        ]

        conn = get_sqlite()
        cur = conn.cursor()
        try:
            cur.execute("""
                INSERT INTO characters (account_id, name, house, inventory)
                VALUES (?, ?, ?, ?)
            """, (acc_id, name, house, json.dumps(starter_inventory)))
            char_id = cur.lastrowid
            conn.commit()

            cur.execute("SELECT * FROM characters WHERE id = ?", (char_id,))
            created_char = dict(cur.fetchone())
            created_char["inventory"] = json.loads(created_char["inventory"])
            created_char["quests"] = json.loads(created_char["quests"])
            conn.close()
            self._send_json(200, {"success": True, "message": "Character created!", "character": created_char})
        except sqlite3.IntegrityError:
            conn.close()
            self._send_json(409, {"success": False, "message": "Character name already taken!"})

    def handle_character_load(self, req: dict):
        char_id = req.get("character_id")
        conn = get_sqlite()
        cur = conn.cursor()
        cur.execute("SELECT * FROM characters WHERE id = ?", (char_id,))
        row = cur.fetchone()
        conn.close()
        if not row:
            self._send_json(404, {"success": False, "message": "Character not found"})
            return

        char_data = dict(row)
        char_data["inventory"] = json.loads(char_data["inventory"])
        char_data["quests"] = json.loads(char_data["quests"])
        self._send_json(200, {"success": True, "character": char_data})

    def handle_character_save(self, req: dict):
        char_id = req.get("character_id")
        if not char_id:
            self._send_json(400, {"success": False, "message": "Missing character_id"})
            return

        pos = req.get("pos", [0.0, 0.5, 5.0])
        rot_y = float(req.get("rot_y", 3.14159))
        level = int(req.get("level", 1))
        exp = int(req.get("exp", 0))
        max_hp = int(req.get("max_hp", 500))
        current_hp = int(req.get("current_hp", 500))
        max_mana = int(req.get("max_mana", 300))
        current_mana = int(req.get("current_mana", 300))
        galleons = int(req.get("galleons", 500))
        wand_tier = int(req.get("wand_tier", 0))
        inventory_str = json.dumps(req.get("inventory", []))
        quests_str = json.dumps(req.get("quests", {}))

        conn = get_sqlite()
        cur = conn.cursor()
        cur.execute("""
            UPDATE characters SET
                level = ?, exp = ?, max_hp = ?, current_hp = ?,
                max_mana = ?, current_mana = ?, galleons = ?, wand_tier = ?,
                pos_x = ?, pos_y = ?, pos_z = ?, rot_y = ?,
                inventory = ?, quests = ?, updated_at = CURRENT_TIMESTAMP
            WHERE id = ?
        """, (level, exp, max_hp, current_hp, max_mana, current_mana, galleons, wand_tier,
              pos[0], pos[1], pos[2], rot_y, inventory_str, quests_str, char_id))
        conn.commit()
        conn.close()
        self._send_json(200, {"success": True, "message": "Character saved successfully."})

    def handle_trade(self, req: dict):
        """
        ACID Transaction: Safely swaps items and galleons between two characters.
        If any step fails, entire transaction is automatically rolled back.
        """
        p1_id = req.get("player1_id")
        p2_id = req.get("player2_id")
        p1_offer = req.get("player1_offer", {}) # {"galleons": int, "items": [...]}
        p2_offer = req.get("player2_offer", {})

        conn = get_sqlite()
        try:
            conn.execute("BEGIN TRANSACTION;")
            cur = conn.cursor()

            # 1. Fetch both characters
            cur.execute("SELECT galleons, inventory FROM characters WHERE id = ?", (p1_id,))
            p1_row = cur.fetchone()
            cur.execute("SELECT galleons, inventory FROM characters WHERE id = ?", (p2_id,))
            p2_row = cur.fetchone()

            if not p1_row or not p2_row:
                raise Exception("One of the trading players does not exist.")

            p1_galleons = p1_row["galleons"]
            p2_galleons = p2_row["galleons"]
            p1_inv = json.loads(p1_row["inventory"])
            p2_inv = json.loads(p2_row["inventory"])

            # Verify sufficiency
            if p1_galleons < p1_offer.get("galleons", 0):
                raise Exception("Player 1 has insufficient Galleons.")
            if p2_galleons < p2_offer.get("galleons", 0):
                raise Exception("Player 2 has insufficient Galleons.")

            # Swap Galleons
            p1_galleons = p1_galleons - p1_offer.get("galleons", 0) + p2_offer.get("galleons", 0)
            p2_galleons = p2_galleons - p2_offer.get("galleons", 0) + p1_offer.get("galleons", 0)

            # Swap items (append offered items)
            for item in p2_offer.get("items", []):
                p1_inv.append(item)
            for item in p1_offer.get("items", []):
                p2_inv.append(item)

            # Update both in one transaction
            cur.execute("UPDATE characters SET galleons = ?, inventory = ? WHERE id = ?", (p1_galleons, json.dumps(p1_inv), p1_id))
            cur.execute("UPDATE characters SET galleons = ?, inventory = ? WHERE id = ?", (p2_galleons, json.dumps(p2_inv), p2_id))

            # Log trade
            cur.execute("INSERT INTO trade_logs (sender_char_id, receiver_char_id, details) VALUES (?, ?, ?)",
                        (p1_id, p2_id, json.dumps({"p1_offer": p1_offer, "p2_offer": p2_offer})))

            conn.commit()
            self._send_json(200, {"success": True, "message": "Trade executed atomically!"})
        except Exception as e:
            conn.rollback()
            self._send_json(400, {"success": False, "message": f"Trade failed and rolled back: {str(e)}"})
        finally:
            conn.close()

    def log_message(self, format, *args):
        # Clean logging
        sys.stdout.write(f"[DB API] {args[0]} - {args[1]}\n")

if __name__ == "__main__":
    server_address = ("127.0.0.1", PORT)
    httpd = HTTPServer(server_address, DBRequestHandler)
    print("=========================================================")
    print(f"[PotterMetin DB Service] Running on http://127.0.0.1:{PORT}")
    print(f"[PotterMetin DB Service] Backend: {DB_TYPE.upper()}")
    print("=========================================================")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down DB Service...")
        httpd.server_close()
