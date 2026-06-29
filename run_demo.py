"""
run_demo.py — Executes the order2cash-demo scripts against a live Oracle DB.

Connects as SYSDBA to create the schema, then reconnects as ORDER2CASH to
run seed data, compile the package, and run the test suite.
Captures DBMS_OUTPUT and prints it to stdout (and optionally to a file).
"""

import oracledb
import sys
import os

# ── Connection parameters ─────────────────────────────────────────────────────
DSN        = "localhost:1521/FREEPDB1"
SYSDBA_USER = "sys"
SYSDBA_PWD  = "YourStrongPwd123"
APP_USER    = "order2cash"
APP_PWD     = "Order2cashPwd#1"

BASE = os.path.dirname(os.path.abspath(__file__))

def read_sql(path):
    with open(os.path.join(BASE, path), encoding="utf-8") as f:
        return f.read()

def split_statements(sql_text):
    """
    Split a SQL file into individual statements.
    Handles PL/SQL blocks terminated by '/' on its own line,
    and plain DML terminated by ';'.
    """
    statements = []
    current = []
    in_plsql = False

    for line in sql_text.splitlines():
        stripped = line.strip()

        # Skip comment-only lines at top level
        if stripped.startswith("--") and not in_plsql:
            continue

        # PL/SQL block delimiter on its own line
        if stripped == "/" :
            if current:
                statements.append("\n".join(current).strip())
                current = []
            in_plsql = False
            continue

        current.append(line)

        # Detect start of PL/SQL block
        if stripped.upper().startswith(("BEGIN", "DECLARE", "CREATE OR REPLACE")):
            in_plsql = True

        # Plain SQL statement terminator (not inside a PL/SQL block)
        if not in_plsql and stripped.endswith(";"):
            stmt = "\n".join(current).strip().rstrip(";")
            if stmt:
                statements.append(stmt)
            current = []

    if current:
        stmt = "\n".join(current).strip()
        if stmt:
            statements.append(stmt)

    return [s for s in statements if s.strip()]


def run_statements(conn, sql_text, label=""):
    """Execute each statement in sql_text; print progress."""
    stmts = split_statements(sql_text)
    for i, stmt in enumerate(stmts, 1):
        preview = stmt.split("\n")[0][:80]
        try:
            with conn.cursor() as cur:
                cur.execute(stmt)
            print(f"  [{label} #{i}] OK  — {preview}")
        except oracledb.DatabaseError as e:
            print(f"  [{label} #{i}] ERR — {preview}")
            print(f"    ERROR: {e}")
            raise


def fetch_dbms_output(conn):
    """Drain DBMS_OUTPUT buffer and return as a list of lines."""
    lines = []
    with conn.cursor() as cur:
        cur.callproc("dbms_output.get_lines", [lines, 1000000])
    return lines


def run_test_block(conn, sql_text):
    """
    Execute an anonymous PL/SQL block that uses DBMS_OUTPUT.
    Handles SET SERVEROUTPUT ON directive by enabling the output buffer.
    Returns the captured output lines.
    """
    # Enable DBMS_OUTPUT buffer (equivalent to SET SERVEROUTPUT ON)
    with conn.cursor() as cur:
        cur.callproc("dbms_output.enable", [1000000])

    # Strip SQL*Plus directives
    clean = "\n".join(
        line for line in sql_text.splitlines()
        if not line.strip().upper().startswith("SET ")
    )

    # The test file is one big DECLARE..BEGIN..END; / block
    # Extract just the PL/SQL block
    lines = clean.splitlines()
    block_lines = []
    collecting = False
    for line in lines:
        s = line.strip().upper()
        if s.startswith("DECLARE") or s.startswith("BEGIN"):
            collecting = True
        if collecting:
            # Stop at the trailing /
            if line.strip() == "/":
                break
            block_lines.append(line)

    block = "\n".join(block_lines).strip()
    if not block:
        raise ValueError("Could not extract PL/SQL block from test file")

    with conn.cursor() as cur:
        cur.execute(block)

    # Drain DBMS_OUTPUT one line at a time using get_line
    output = []
    with conn.cursor() as cur:
        status_var = cur.var(int)
        line_var   = cur.var(str)
        while True:
            cur.callproc("dbms_output.get_line", [line_var, status_var])
            if status_var.getvalue() != 0:
                break
            val = line_var.getvalue()
            output.append(val if val is not None else "")

    return output


def main():
    # Force UTF-8 on Windows consoles that default to cp1252
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

    print("=" * 60)
    print("order2cash-demo: connecting to Oracle at", DSN)
    print("=" * 60)

    # ── Step 1: SYSDBA — create schema ───────────────────────────────────────
    print("\n[1/4] Running 01_schema.sql as SYSDBA ...")
    sysdba_conn = oracledb.connect(
        user=SYSDBA_USER,
        password=SYSDBA_PWD,
        dsn=DSN,
        mode=oracledb.AUTH_MODE_SYSDBA
    )
    sysdba_conn.autocommit = True

    # Kill any open ORDER2CASH sessions before DROP USER (ORA-01940 guard).
    # We do this in Python so we can pause until Oracle fully clears them.
    import time
    with sysdba_conn.cursor() as _cur:
        _cur.execute(
            "SELECT sid, serial# FROM v$session WHERE username = 'ORDER2CASH'"
        )
        sessions = _cur.fetchall()
    for sid, serial in sessions:
        try:
            with sysdba_conn.cursor() as _cur:
                _cur.execute(
                    f"ALTER SYSTEM KILL SESSION '{sid},{serial}' IMMEDIATE"
                )
            print(f"  Killed session SID={sid},SERIAL={serial}")
        except Exception:
            pass  # already gone
    if sessions:
        time.sleep(3)  # let Oracle clear the dead sessions before DROP USER

    run_statements(sysdba_conn, read_sql("sql/01_schema.sql"), "schema")
    sysdba_conn.close()
    print("  Schema created.")

    # ── Step 2: ORDER2CASH — seed data ───────────────────────────────────────
    print("\n[2/4] Running 02_seed_data.sql as ORDER2CASH ...")
    app_conn = oracledb.connect(user=APP_USER, password=APP_PWD, dsn=DSN)
    app_conn.autocommit = False
    run_statements(app_conn, read_sql("sql/02_seed_data.sql"), "seed")
    app_conn.commit()
    print("  Seed data inserted.")

    # ── Step 3: Compile package ───────────────────────────────────────────────
    print("\n[3/4] Compiling pkg_order_mgmt (spec then body) ...")
    spec_sql = read_sql("sql/03_pkg_order_mgmt_spec.sql")
    body_sql = read_sql("sql/04_pkg_order_mgmt_body.sql")

    # Package spec and body are each a single CREATE OR REPLACE … / block
    def extract_plsql(text):
        lines = text.splitlines()
        block = []
        for line in lines:
            if line.strip() == "/":
                break
            if not line.strip().startswith("--"):
                block.append(line)
        return "\n".join(block).strip()

    with app_conn.cursor() as cur:
        cur.execute(extract_plsql(spec_sql))
        print("  Spec compiled.")
        cur.execute(extract_plsql(body_sql))
        print("  Body compiled.")

    # Check for compilation errors
    with app_conn.cursor() as cur:
        cur.execute("""
            SELECT type, line, position, text
              FROM user_errors
             WHERE name = 'PKG_ORDER_MGMT'
             ORDER BY type, sequence
        """)
        errors = cur.fetchall()
        if errors:
            print("\n  COMPILATION ERRORS:")
            for row in errors:
                print(f"    {row[0]} line {row[1]}:{row[2]} — {row[3]}")
            sys.exit(1)
        else:
            print("  No compilation errors.")

    # ── Step 4: Run test suite ────────────────────────────────────────────────
    print("\n[4/4] Running test suite ...")
    print("-" * 60)
    output_lines = run_test_block(app_conn, read_sql("test/test_pkg_order_mgmt.sql"))

    for line in output_lines:
        print(line)

    app_conn.close()

    print("-" * 60)
    print("\nCapturing output to test/sample_output.txt ...")

    output_text = "\n".join(output_lines)
    out_path = os.path.join(BASE, "test", "sample_output.txt")
    with open(out_path, "w", encoding="utf-8") as f:
        f.write("order2cash-demo: pkg_order_mgmt test run\n")
        f.write("=" * 60 + "\n")
        f.write(output_text)
        f.write("\n")

    print(f"Done. Output saved to {out_path}")

    # Check for FAILED in output
    if any("FAILED" in line or "ERROR:" in line for line in output_lines):
        print("\n*** One or more tests FAILED — review output above ***")
        sys.exit(1)
    else:
        print("\nAll tests PASSED.")


if __name__ == "__main__":
    main()
