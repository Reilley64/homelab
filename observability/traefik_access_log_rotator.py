from __future__ import annotations

import gzip
import os
import shutil
import sys
import time


def rotate_if_needed(path: str, max_bytes: int, copies: int) -> bool:
    try:
        if os.path.getsize(path) < max_bytes:
            return False
    except FileNotFoundError:
        return False
    oldest = f"{path}.{copies}.gz"
    if os.path.exists(oldest):
        os.unlink(oldest)
    for index in range(copies - 1, 0, -1):
        source = f"{path}.{index}.gz"
        if os.path.exists(source):
            os.replace(source, f"{path}.{index + 1}.gz")
    with open(path, "rb") as source, gzip.open(f"{path}.1.gz", "wb") as destination:
        shutil.copyfileobj(source, destination)
    with open(path, "r+b") as active:
        active.truncate(0)
    return True


def positive_integer(name: str, default: str) -> int:
    value = int(os.environ.get(name, default))
    if value <= 0:
        raise ValueError(f"{name} must be positive")
    return value


def main() -> None:
    path = os.environ.get("ACCESS_LOG_PATH", "/logs/access.json")
    max_bytes = positive_integer("LOG_MAX_BYTES", "104857600")
    copies = positive_integer("LOG_COPIES", "7")
    interval = positive_integer("ROTATION_CHECK_SECONDS", "60")
    while True:
        try:
            rotate_if_needed(path, max_bytes, copies)
        except Exception as error:
            print(f"access-log rotation failed: {error}", file=sys.stderr, flush=True)
        time.sleep(interval)


if __name__ == "__main__":
    main()
