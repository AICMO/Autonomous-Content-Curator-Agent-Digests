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
from html.parser import HTMLParser
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

        # Verify connection and get default newsletter
        self._get("/site/")
        newsletters = self._get("/newsletters/").get("newsletters", [])
        self.newsletter_slug = newsletters[0]["slug"] if newsletters else None
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

    def create_post(self, title: str, lexical: str, status: str = "draft", newsletter_slug: str = None):
        """Create a post. status: 'draft' or 'published'. newsletter_slug sends email to subscribers."""
        post = {
            "title": title,
            "lexical": lexical,
            "status": status,
        }
        if newsletter_slug and status == "published":
            post["email_segment"] = "all"

        path = "/posts/"
        if newsletter_slug and status == "published":
            path = f"/posts/?newsletter={newsletter_slug}"

        return self._post(path, json={"posts": [post]})


# ============================================================
# HTML → Ghost Lexical converter
# ============================================================

# Lexical format bitmask: bold=1, italic=2
FORMAT_BOLD = 1
FORMAT_ITALIC = 2


def _text_node(text, fmt=0):
    return {"detail": 0, "format": fmt, "mode": "normal", "style": "", "text": text, "type": "extended-text", "version": 1}


def _link_node(url, children):
    return {"children": children, "direction": None, "format": "", "indent": 0, "type": "link", "version": 1, "rel": "noopener", "target": None, "title": None, "url": url}


class _HTMLToLexical(HTMLParser):
    """Parse HTML into Ghost Lexical JSON nodes."""

    def __init__(self):
        super().__init__()
        self.nodes = []          # top-level Lexical block nodes
        self.inline = []         # inline children for current block
        self.list_items = []     # collected list items
        self.list_tag = None     # "ol" or "ul"
        self.block_tag = None    # current block tag (p, h2, h3, li)
        self.fmt = 0             # current inline format bitmask
        self.link_url = None     # current <a> href

    def _flush_block(self):
        if not self.inline:
            return
        children = list(self.inline)
        self.inline.clear()

        if self.block_tag in ("h1", "h2", "h3", "h4"):
            self.nodes.append({"children": children, "direction": None, "format": "", "indent": 0, "type": "heading", "tag": self.block_tag, "version": 1})
        elif self.block_tag == "li":
            self.list_items.append({"children": children, "direction": None, "format": "", "indent": 0, "type": "listitem", "value": len(self.list_items) + 1, "version": 1})
        else:
            self.nodes.append({"children": children, "direction": None, "format": "", "indent": 0, "type": "paragraph", "version": 1})
        self.block_tag = None

    def _flush_list(self):
        if not self.list_items:
            return
        list_type = "number" if self.list_tag == "ol" else "bullet"
        self.nodes.append({"children": list(self.list_items), "direction": None, "format": "", "indent": 0, "type": "list", "listType": list_type, "start": 1, "tag": self.list_tag or "ol", "version": 1})
        self.list_items.clear()
        self.list_tag = None

    def handle_starttag(self, tag, attrs):
        attrs_d = dict(attrs)
        if tag in ("h1", "h2", "h3", "h4", "p"):
            self.block_tag = tag
        elif tag in ("ol", "ul"):
            self.list_tag = tag
        elif tag == "li":
            self.block_tag = "li"
        elif tag in ("strong", "b"):
            self.fmt |= FORMAT_BOLD
        elif tag in ("em", "i"):
            self.fmt |= FORMAT_ITALIC
        elif tag == "a":
            self.link_url = attrs_d.get("href")

    def handle_endtag(self, tag):
        if tag in ("h1", "h2", "h3", "h4", "p", "li"):
            self._flush_block()
        elif tag in ("ol", "ul"):
            self._flush_list()
        elif tag in ("strong", "b"):
            self.fmt &= ~FORMAT_BOLD
        elif tag in ("em", "i"):
            self.fmt &= ~FORMAT_ITALIC
        elif tag == "a":
            self.link_url = None

    def handle_data(self, data):
        if not data.strip() and not self.block_tag:
            return
        if self.link_url:
            self.inline.append(_link_node(self.link_url, [_text_node(data, self.fmt)]))
        else:
            self.inline.append(_text_node(data, self.fmt))


def html_to_lexical(html: str) -> str:
    """Convert HTML string to Ghost Lexical JSON string."""
    parser = _HTMLToLexical()
    parser.feed(html)
    parser._flush_block()
    parser._flush_list()
    root = {"root": {"children": parser.nodes, "direction": None, "format": "", "indent": 0, "type": "root", "version": 1}}
    return json.dumps(root)


# ============================================================
# Title prefix
# ============================================================

def _digest_title(since_hours: float = 24, start_date: str = None, end_date: str = None) -> str:
    """Build digest title from time range. e.g. '[Daily] AI Digest — March 10, 2026'."""
    start_date = start_date or None  # treat empty string as None
    end_date = end_date or None
    if start_date:
        end = datetime.strptime(end_date, "%Y-%m-%d") if end_date else datetime.now(timezone.utc)
        start = datetime.strptime(start_date, "%Y-%m-%d")
        span_hours = (end - start).total_seconds() / 3600 + 24  # include full end day
        date_str = end.strftime("%B %d, %Y")
    else:
        span_hours = since_hours
        date_str = datetime.now(timezone.utc).strftime("%B %d, %Y")

    if span_hours <= 24:
        prefix = "[Daily] "
    elif span_hours <= 168:
        prefix = "[Weekly] "
    else:
        prefix = ""

    return f"{prefix}AI Digest — {date_str}"


# ============================================================
# CLI
# ============================================================

def cmd_post(draft_only: bool = False, custom_title: str = None, since_hours: float = 24, start_date: str = None, end_date: str = None):
    if not LLM_RESPONSE_TMP.exists():
        print(f"Error: {LLM_RESPONSE_TMP} not found. Run the LLM pipeline first.")
        sys.exit(1)

    digest_text = LLM_RESPONSE_TMP.read_text().strip()
    if not digest_text:
        print("LLM response is empty, nothing to publish.")
        return

    api_url = os.environ.get("GHOST_URL", "").strip()
    if api_url and not api_url.startswith("http"):
        api_url = f"https://{api_url}"
    admin_key = os.environ.get("GHOST_ADMIN_API_KEY", "").strip()

    if not api_url:
        print("Error: GHOST_URL environment variable not set")
        sys.exit(1)
    if not admin_key:
        print("Error: GHOST_ADMIN_API_KEY environment variable not set")
        sys.exit(1)

    print(f"Connecting to Ghost ({api_url})...")
    api = GhostApi(api_url=api_url, admin_api_key=admin_key)

    title = custom_title or _digest_title(since_hours, start_date, end_date)
    lexical = html_to_lexical(digest_text)
    print(f"Content: {len(digest_text)} chars → {len(lexical)} chars Lexical")

    status = "draft" if draft_only else "published"
    result = api.create_post(title=title, lexical=lexical, status=status, newsletter_slug=api.newsletter_slug)
    if api.newsletter_slug and status == "published":
        print(f"Email sent to newsletter: {api.newsletter_slug}")

    post = result["posts"][0]
    if draft_only:
        print(f"Draft created: {api_url}/ghost/#/editor/post/{post['id']}")
    else:
        print(f"Published: {post.get('url', '')}")

    print("Done.")


def main():
    parser = argparse.ArgumentParser(description="Ghost Publisher")
    parser.add_argument("--post", action="store_true", help="Publish /tmp/llm_response.txt to Ghost")
    parser.add_argument("--draft", action="store_true", help="Create draft only, don't publish")
    parser.add_argument("--title", type=str, help="Custom post title (default: AI Digest — <date>)")
    parser.add_argument("--since-hours", type=float, default=24, help="Hours of content (for title prefix)")
    parser.add_argument("--start-date", type=str, help="Start date YYYY-MM-DD (for title)")
    parser.add_argument("--end-date", type=str, help="End date YYYY-MM-DD (for title)")
    args = parser.parse_args()

    if not args.post:
        parser.print_help()
        sys.exit(1)

    cmd_post(draft_only=args.draft, custom_title=args.title, since_hours=args.since_hours, start_date=args.start_date, end_date=args.end_date)


if __name__ == "__main__":
    main()
