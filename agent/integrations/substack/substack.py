#!/usr/bin/env python3
"""Substack publisher — reads LLM digest and publishes to Substack.

Usage:
  python substack.py --post              # Publish /tmp/llm_response.txt
  python substack.py --post --draft      # Create draft only (don't publish)

API vendored from python-substack (https://github.com/ma2za/python-substack).
"""

import argparse
import json
import os
import re
import sys
from datetime import datetime, timezone
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urljoin, unquote

import requests

LLM_RESPONSE_TMP = Path("/tmp/llm_response.txt")


# ============================================================
# Substack API client (minimal)
# ============================================================

class SubstackError(Exception):
    def __init__(self, status_code, text):
        try:
            json_res = json.loads(text)
            self.message = ", ".join(
                e.get("msg", "") for e in json_res.get("errors", [])
            ) or json_res.get("error", "")
        except ValueError:
            self.message = f"Invalid response: {text}"
        self.status_code = status_code

    def __str__(self):
        return f"SubstackError(code={self.status_code}): {self.message}"


class SubstackApi:
    """Minimal Substack API client — cookie auth, create draft, publish."""

    def __init__(self, cookies_string: str, publication_url: str):
        self.base_url = "https://substack.com/api/v1"
        self._session = requests.Session()
        self._session.headers.update({
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
            "Accept": "application/json, text/plain, */*",
            "Accept-Language": "en-US,en;q=0.9",
            "Accept-Encoding": "gzip, deflate",
            "Origin": "https://substack.com",
            "Referer": "https://substack.com/",
            "Sec-Fetch-Dest": "empty",
            "Sec-Fetch-Mode": "cors",
            "Sec-Fetch-Site": "same-origin",
            "Sec-Ch-Ua": '"Google Chrome";v="131", "Chromium";v="131", "Not_A Brand";v="24"',
            "Sec-Ch-Ua-Mobile": "?0",
            "Sec-Ch-Ua-Platform": '"macOS"',
        })

        # Parse cookie string
        for pair in cookies_string.split(";"):
            pair = pair.strip()
            if "=" in pair:
                key, value = pair.split("=", 1)
                self._session.cookies.set(key.strip(), unquote(value.strip()))

        # Try native API first, fall back to subdomain API (avoids Cloudflare on substack.com)
        match = re.search(r"https://(.*).substack.com", publication_url.lower())
        subdomain = match.group(1) if match else None
        subdomain_base_url = f"{publication_url.rstrip('/')}/api/v1"

        try:
            profile = self._get(f"{self.base_url}/user/profile/self")
            print("Using native API (substack.com)")
        except SubstackError:
            print("Native API blocked, falling back to subdomain API")
            self.base_url = subdomain_base_url
            profile = self._get(f"{self.base_url}/user/profile/self")

        # Find matching publication
        publication = None
        for pub_user in profile.get("publicationUsers", []):
            pub = pub_user.get("publication")
            if pub and pub.get("subdomain") == subdomain:
                publication = pub
                break

        if not publication:
            # Fall back to primary
            publication = profile.get("primaryPublication")
            if not publication:
                for pub_user in profile.get("publicationUsers", []):
                    if pub_user.get("is_primary"):
                        publication = pub_user.get("publication")
                        break

        if not publication:
            raise SubstackError(0, '{"error": "Could not find publication"}')

        custom_domain = publication.get("custom_domain")
        if custom_domain and not publication.get("custom_domain_optional"):
            base = f"https://{custom_domain}"
        else:
            base = f"https://{publication['subdomain']}.substack.com"

        self.publication_api = urljoin(base, "api/v1")
        self.user_id = profile["id"]

    def _handle(self, response):
        if not (200 <= response.status_code < 300):
            raise SubstackError(response.status_code, response.text)
        return response.json()

    def _get(self, url, **kwargs):
        return self._handle(self._session.get(url, **kwargs))

    def _post(self, url, **kwargs):
        return self._handle(self._session.post(url, **kwargs))

    def create_draft(self, title, subtitle, body_content):
        """Create a draft post. body_content: list of ProseMirror nodes."""
        draft_body = {
            "draft_title": title,
            "draft_subtitle": subtitle,
            "draft_body": json.dumps({"type": "doc", "content": body_content}),
            "draft_bylines": [{"id": self.user_id, "is_guest": False}],
            "audience": "everyone",
            "section_chosen": True,
        }
        return self._post(f"{self.publication_api}/drafts", json=draft_body)

    def publish(self, draft_id, send_email=False):
        """Prepublish checks then publish a draft."""
        self._get(f"{self.publication_api}/drafts/{draft_id}/prepublish")
        return self._post(
            f"{self.publication_api}/drafts/{draft_id}/publish",
            json={"send": send_email, "share_automatically": False},
        )


# ============================================================
# HTML → Substack ProseMirror converter
# ============================================================

class _HTMLToProseMirror(HTMLParser):
    """Parse HTML into Substack ProseMirror JSON nodes."""

    def __init__(self):
        super().__init__()
        self.nodes = []          # top-level ProseMirror block nodes
        self.inline = []         # inline content for current block
        self.list_items = []     # collected list items
        self.list_tag = None     # "ol" or "ul"
        self.block_tag = None    # current block tag
        self.marks = []          # active inline marks stack

    def _flush_block(self):
        if not self.inline:
            return
        content = list(self.inline)
        self.inline.clear()

        if self.block_tag in ("h1", "h2", "h3", "h4"):
            level = int(self.block_tag[1])
            self.nodes.append({"type": "heading", "attrs": {"level": level}, "content": content})
        elif self.block_tag == "li":
            self.list_items.append({"type": "list_item", "content": [{"type": "paragraph", "content": content}]})
        else:
            self.nodes.append({"type": "paragraph", "content": content})
        self.block_tag = None

    def _flush_list(self):
        if not self.list_items:
            return
        list_type = "ordered_list" if self.list_tag == "ol" else "bullet_list"
        self.nodes.append({"type": list_type, "content": list(self.list_items)})
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
            self.marks.append({"type": "bold"})
        elif tag in ("em", "i"):
            self.marks.append({"type": "italic"})
        elif tag == "a":
            self.marks.append({"type": "link", "attrs": {"href": attrs_d.get("href", "")}})

    def handle_endtag(self, tag):
        if tag in ("h1", "h2", "h3", "h4", "p", "li"):
            self._flush_block()
        elif tag in ("ol", "ul"):
            self._flush_list()
        elif tag in ("strong", "b"):
            self.marks = [m for m in self.marks if m["type"] != "bold"]
        elif tag in ("em", "i"):
            self.marks = [m for m in self.marks if m["type"] != "italic"]
        elif tag == "a":
            self.marks = [m for m in self.marks if m["type"] != "link"]

    def handle_data(self, data):
        if not data.strip() and not self.block_tag:
            return
        node = {"type": "text", "text": data}
        if self.marks:
            node["marks"] = list(self.marks)
        self.inline.append(node)


def html_to_prosemirror(html: str) -> list:
    """Convert HTML string to list of Substack ProseMirror nodes."""
    parser = _HTMLToProseMirror()
    parser.feed(html)
    parser._flush_block()
    parser._flush_list()
    return parser.nodes


# ============================================================
# Title prefix
# ============================================================

def _digest_title(since_hours: float = 24, start_date: str = None, end_date: str = None) -> str:
    """Build digest title from time range."""
    start_date = start_date or None
    end_date = end_date or None
    if start_date:
        end = datetime.strptime(end_date, "%Y-%m-%d") if end_date else datetime.now(timezone.utc)
        start = datetime.strptime(start_date, "%Y-%m-%d")
        span_hours = (end - start).total_seconds() / 3600 + 24
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

def cmd_post(draft_only: bool = False, since_hours: float = 24, start_date: str = None, end_date: str = None):
    if not LLM_RESPONSE_TMP.exists():
        print(f"Error: {LLM_RESPONSE_TMP} not found. Run the LLM pipeline first.")
        sys.exit(1)

    digest_text = LLM_RESPONSE_TMP.read_text().strip()
    if not digest_text:
        print("LLM response is empty, nothing to publish.")
        return

    cookie = os.environ.get("SUBSTACK_COOKIE")
    pub_url = os.environ.get("SUBSTACK_PUBLICATION_URL", "").strip()

    if not cookie:
        print("Error: SUBSTACK_COOKIE environment variable not set")
        sys.exit(1)
    if not pub_url:
        print("Error: SUBSTACK_PUBLICATION_URL environment variable not set")
        sys.exit(1)

    print(f"Connecting to Substack ({pub_url})...")
    api = SubstackApi(
        cookies_string=f"connect.sid={cookie}",
        publication_url=pub_url,
    )
    print(f"Authenticated as user {api.user_id}")

    title = _digest_title(since_hours, start_date, end_date)

    body_content = html_to_prosemirror(digest_text)
    print(f"Content: {len(digest_text)} chars → {len(body_content)} ProseMirror nodes")

    draft = api.create_draft(title=title, subtitle="", body_content=body_content)
    draft_id = draft.get("id")
    print(f"Draft created: id={draft_id}")

    if draft_only:
        print(f"Draft only: {pub_url}/publish/posts/drafts")
    else:
        result = api.publish(draft_id, send_email=False)
        slug = result.get("slug", draft_id)
        print(f"Published: {pub_url}/p/{slug}")

    print("Done.")


def main():
    parser = argparse.ArgumentParser(description="Substack Publisher")
    parser.add_argument("--post", action="store_true", help="Publish /tmp/llm_response.txt to Substack")
    parser.add_argument("--draft", action="store_true", help="Create draft only, don't publish")
    parser.add_argument("--since-hours", type=float, default=24, help="Hours of content (for title prefix)")
    parser.add_argument("--start-date", type=str, help="Start date YYYY-MM-DD (for title)")
    parser.add_argument("--end-date", type=str, help="End date YYYY-MM-DD (for title)")
    args = parser.parse_args()

    if not args.post:
        parser.print_help()
        sys.exit(1)

    cmd_post(draft_only=args.draft, since_hours=args.since_hours, start_date=args.start_date, end_date=args.end_date)


if __name__ == "__main__":
    main()