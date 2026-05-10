"""Print a PocketBase user JWT to stdout (paste into Swagger Authorize)."""

from __future__ import annotations

import sys


def main() -> None:
    from script_agent.integrations.pocketbase.client import auth_with_password, dev_access_token

    if len(sys.argv) == 3:
        token = auth_with_password(sys.argv[1], sys.argv[2]).token
    elif len(sys.argv) == 1:
        token = dev_access_token()
    else:
        sys.stderr.write(
            "usage: pb-token [identity password]\n"
            "  default: SCRIPT_POCKETBASE_DEV_IDENTITY and SCRIPT_POCKETBASE_DEV_PASSWORD\n",
        )
        raise SystemExit(2)
    sys.stdout.write(token + "\n")


if __name__ == "__main__":
    main()
