"""Synthetic database fixture for disposable Windows installer tests only."""
import argparse
import sqlite3
import uuid
from pathlib import Path


def run(mode, database, fixture_id):
    token = uuid.UUID(fixture_id)
    path = Path(database).resolve(strict=True)
    service_id = str(uuid.uuid5(token, "service"))
    identity_id = str(uuid.uuid5(token, "identity"))
    email = f"{token}@example.test"
    with sqlite3.connect(path.as_uri() + "?mode=rw", uri=True, timeout=10) as db:
        db.execute("PRAGMA foreign_keys=ON")
        if mode == "seed":
            db.execute("INSERT INTO services(id,name) VALUES (?,?)", (service_id, "FMS runner fixture"))
            db.execute("INSERT INTO identities(id,identity_type,value) VALUES (?,?,?)", (identity_id, "email", email))
            db.execute("INSERT INTO provider_accounts(id,service_id,identity_id,label) VALUES (?,?,?,?)", (str(token), service_id, identity_id, "Synthetic installer test"))
        else:
            row = db.execute(
                "SELECT a.label,s.name,i.value FROM provider_accounts a "
                "JOIN services s ON s.id=a.service_id "
                "JOIN identities i ON i.id=a.identity_id WHERE a.id=?",
                (str(token),),
            ).fetchone()
            if row != ("Synthetic installer test", "FMS runner fixture", email):
                raise RuntimeError("Synthetic account fixture was not preserved.")
        if db.execute("PRAGMA integrity_check").fetchone() != ("ok",):
            raise RuntimeError("Database integrity check failed.")
        if db.execute("PRAGMA foreign_key_check").fetchone() is not None:
            raise RuntimeError("Database foreign-key check failed.")
    print(f"Synthetic account fixture {mode} passed.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("seed", "verify"))
    parser.add_argument("database")
    parser.add_argument("fixture_id")
    args = parser.parse_args()
    try:
        run(args.mode, args.database, args.fixture_id)
    except (OSError, ValueError, sqlite3.Error, RuntimeError):
        raise SystemExit("Synthetic metadata fixture check failed; profile contents were not printed.")
