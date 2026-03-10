#!/usr/bin/env python3
"""Ghost publisher — reads LLM digest and publishes to Ghost.

Usage:
  python ghost.py --post              # Publish /tmp/llm_response.txt
  python ghost.py --post --draft      # Create draft only (don't publish)

Auth: Ghost Admin API key (format: {id}:{secret}).
"""

import argparse
import hashlib
import hmac
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

import requests

LLM_RESPONSE_TMP = Path("/tmp/llm_response.txt")


# ============================================================
# Ghost Admin API client
# ============================================================

class GhostError(Exception):
    def __init__(self, status_code, text):
        try:
            json_res = json.loads(text)
            errors = json_res.get("errors", [])
            self.message = "; ".join(e.get("message", "") for e in errors) or text
        except ValueError:
            self.message = f"Invalid response: {text}"
        self.status_code = status_code

    def __str__(self):
        return f"GhostError(code={self.status_code}): {self.message}"


class GhostApi:
    """Minimal Ghost Admin API client — JWT auth, create/publish posts."""

    def __init__(self, api_url: str, admin_api_key: str):
        parts = admin_api_key.split(":")
        if len(parts) != 2:
            raise GhostError(0, '{"errors": [{"message": "Admin API key must be id:secret"}]}')

        self.key_id = parts[0]
        self.secret = bytes.fromhex(parts[1])
        self.api_url = api_url.rstrip("/")
        self.admin_url = f"{self.api_url}/ghost/api/admin"

        # Verify connection
        self._get("/site/")
        print(f"Connected to {self.api_url}")

    def _make_token(self):
        """Create a short-lived JWT for Ghost Admin API (HS256, no dependencies)."""
        import base64
        import time

        header = {"alg": "HS256", "typ": "JWT", "kid": self.key_id}
        now = int(time.time())
        payload = {"iat": now, "exp": now + 300, "aud": "/admin/"}

        def b64url(data):
            return base64.urlsafe_b64encode(json.dumps(data).encode()).rstrip(b"=").decode()

        segments = f"{b64url(header)}.{b64url(payload)}"
        signature = hmac.new(self.secret, segments.encode(), hashlib.sha256).digest()
        sig_encoded = base64.urlsafe_b64encode(signature).rstrip(b"=").decode()
        return f"{segments}.{sig_encoded}"

    def _headers(self):
        return {"Authorization": f"Ghost {self._make_token()}"}

    def _handle(self, response):
        if not (200 <= response.status_code < 300):
            raise GhostError(response.status_code, response.text)
        return response.json()

    def _get(self, path):
        return self._handle(requests.get(f"{self.admin_url}{path}", headers=self._headers()))

    def _post(self, path, **kwargs):
        return self._handle(requests.post(f"{self.admin_url}{path}", headers=self._headers(), **kwargs))

    def _put(self, path, **kwargs):
        return self._handle(requests.put(f"{self.admin_url}{path}", headers=self._headers(), **kwargs))

    def create_post(self, title: str, html: str, status: str = "draft"):
        """Create a post. status: 'draft' or 'published'."""
        payload = {
            "posts": [{
                "title": title,
                "html": html,
                "status": status,
            }]
        }
        return self._post("/posts/", json=payload)


# ============================================================
# Content formatting
# ============================================================

def digest_to_html(text: str) -> str:
    """Convert plain-text LLM digest to HTML for Ghost."""
    lines = text.split("\n")
    html_parts = []
    in_list = False

    for line in lines:
        stripped = line.strip()
        if not stripped:
            if in_list:
                html_parts.append("</ol>")
                in_list = False
            continue

        # Numbered list items (e.g. "1. Item text")
        if len(stripped) > 2 and stripped[0].isdigit() and ". " in stripped[:5]:
            if not in_list:
                html_parts.append("<ol>")
                in_list = True
            item_text = stripped.split(". ", 1)[1]
            html_parts.append(f"<li>{item_text}</li>")
        # Headings (lines that are short and don't end with punctuation)
        elif len(stripped) < 80 and not stripped[-1] in ".,;:!?" and not in_list:
            html_parts.append(f"<h2>{stripped}</h2>")
        else:
            if in_list:
                html_parts.append("</ol>")
                in_list = False
            html_parts.append(f"<p>{stripped}</p>")

    if in_list:
        html_parts.append("</ol>")

    return "\n".join(html_parts)


# ============================================================
# CLI
# ============================================================

def cmd_post(draft_only: bool = False):
    if not LLM_RESPONSE_TMP.exists():
        print(f"Error: {LLM_RESPONSE_TMP} not found. Run the LLM pipeline first.")
        sys.exit(1)

    digest_text = LLM_RESPONSE_TMP.read_text().strip()
    if not digest_text:
        print("LLM response is empty, nothing to publish.")
        return

    api_url = os.environ.get("GHOST_URL", "").strip()
    admin_key = os.environ.get("GHOST_ADMIN_API_KEY", "").strip()

    if not api_url:
        print("Error: GHOST_URL environment variable not set")
        sys.exit(1)
    if not admin_key:
        print("Error: GHOST_ADMIN_API_KEY environment variable not set")
        sys.exit(1)

    print(f"Connecting to Ghost ({api_url})...")
    api = GhostApi(api_url=api_url, admin_api_key=admin_key)

    today = datetime.now(timezone.utc).strftime("%B %d, %Y")
    title = f"AI Digest — {today}"
    html = digest_to_html(digest_text)

    status = "draft" if draft_only else "published"
    result = api.create_post(title=title, html=html, status=status)

    post = result["posts"][0]
    post_url = post.get("url", "")

    if draft_only:
        print(f"Draft created: {api_url}/ghost/#/editor/post/{post['id']}")
    else:
        print(f"Published: {post_url}")

    print("Done.")


def main():
    parser = argparse.ArgumentParser(description="Ghost Publisher")
    parser.add_argument("--post", action="store_true", help="Publish /tmp/llm_response.txt to Ghost")
    parser.add_argument("--draft", action="store_true", help="Create draft only, don't publish")
    args = parser.parse_args()

    if not args.post:
        parser.print_help()
        sys.exit(1)

    cmd_post(draft_only=args.draft)


if __name__ == "__main__":
    main()
