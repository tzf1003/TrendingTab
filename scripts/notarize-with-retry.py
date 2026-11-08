#!/usr/bin/env python3
"""Submit once, then wait on the returned Apple notarization submission ID."""

import argparse
import json
import re
import subprocess
import sys
import time
from pathlib import Path


UUID = re.compile(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}")


def notarize(archive, profile, result):
    def invoke(action, *arguments):
        response = subprocess.run(["xcrun", "notarytool", action, *arguments,
                                   "--keychain-profile", profile, "--output-format", "json"],
                                  capture_output=True, text=True)
        result.write_text(response.stdout)
        try:
            payload = json.loads(response.stdout)
            if not isinstance(payload, dict):
                payload = {}
        except ValueError:
            payload = {}
        return response, payload

    submission = None
    for attempt in range(3):
        response, payload = invoke("submit", str(archive), "--no-wait", "--no-s3-acceleration")
        candidate = payload.get("id")
        if isinstance(candidate, str) and UUID.fullmatch(candidate):
            submission = candidate
            break
        # A reported aborted upload is safe to retry. An ambiguous submission
        # failure without an ID stops here so it cannot create a duplicate.
        transient = any(marker in response.stderr for marker in (
            "connectTimeout", "readTimeout", "connectionClosed", "NSURLErrorDomain -1005"))
        if response.returncode and "abortedUpload(" in response.stderr and transient and attempt < 2:
            print("Apple notarization upload aborted; retrying upload.", flush=True)
            time.sleep((attempt + 1) * 5)
            continue
        raise ValueError("Apple notarization submit did not return a valid submission ID; upload or service failure.")

    for attempt in range(3):
        response, payload = invoke("wait", submission, "--timeout", "5m")
        if payload.get("id", submission) != submission:
            raise ValueError("Apple notarization returned a different submission ID.")
        status = payload.get("status")
        if status == "Accepted":
            print(f"Apple notarization accepted: {submission}")
            return
        if status in ("Invalid", "Rejected"):
            log = result.with_name(result.stem + "-log.json")
            subprocess.run(["xcrun", "notarytool", "log", submission, str(log),
                            "--keychain-profile", profile], check=False)
            raise ValueError(f"Apple notarization {status}: {submission}; see {log.name}.")
        if attempt < 2:
            print(f"Apple notarization pending or wait interrupted; continuing submission {submission}.", flush=True)
            time.sleep((attempt + 1) * 5)
    raise ValueError(f"Apple notarization unfinished: {submission}; resume this submission with notarytool wait.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("--keychain-profile", required=True)
    parser.add_argument("--result", type=Path, required=True)
    args = parser.parse_args()
    try:
        notarize(args.archive, args.keychain_profile, args.result)
    except (ValueError, OSError) as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
