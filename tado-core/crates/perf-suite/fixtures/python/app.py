"""Minimal Python fixture for perf-suite adapter testing.

Hits the Python adapter's DB-query and xproc-roundtrip patterns so the
regex-based detectors can be exercised end-to-end.
"""
import requests
import subprocess


def fetch_users(ids):
    out = []
    for uid in ids:
        r = requests.get(f"https://example.com/users/{uid}")
        out.append(r.json())
    return out


def insert_users(session, users):
    for u in users:
        session.add(u)
    session.commit()


def shell_each(commands):
    for cmd in commands:
        subprocess.run(cmd, check=False)
