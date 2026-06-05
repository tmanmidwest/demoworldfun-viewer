#!/usr/bin/env python3
"""Generate the AUTH_PASS_HASH_B64 value for a login password.

Usage:
    python3 hash_password.py                # prompts (hidden input)
    python3 hash_password.py 'my password'  # arg (may land in shell history)

Output is a single line you can paste straight into .env. The bcrypt hash is
base64-encoded so it never contains '$' characters, which would otherwise be
interpreted by the shell or docker-compose when loading .env.

Requires: pip install bcrypt
"""
import sys
import base64
import getpass

import bcrypt


def main() -> int:
    if len(sys.argv) > 1:
        password = sys.argv[1]
    else:
        password = getpass.getpass("Password: ")
        if password != getpass.getpass("Confirm:  "):
            print("Passwords did not match.", file=sys.stderr)
            return 1

    if not password:
        print("Empty password.", file=sys.stderr)
        return 1
    if len(password.encode("utf-8")) > 72:
        print("Warning: bcrypt only uses the first 72 bytes.", file=sys.stderr)

    raw_hash = bcrypt.hashpw(password.encode("utf-8"), bcrypt.gensalt())
    b64 = base64.b64encode(raw_hash).decode("ascii")
    print()
    print("Add this line to your .env:")
    print(f"AUTH_PASS_HASH_B64={b64}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
