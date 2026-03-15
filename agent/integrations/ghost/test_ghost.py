"""Tests for ghost.py."""

import json
import sys
from pathlib import Path
from unittest.mock import patch, MagicMock
from datetime import datetime, timezone

import pytest

sys.path.insert(0, str(Path(__file__).parent))

from ghost import html_to_lexical, _digest_title, GhostError, GhostApi, cmd_post


# ============================================================
# html_to_lexical
# ============================================================

class TestHtmlToLexical:
    def _parse(self, html):
        return json.loads(html_to_lexical(html))

    def test_paragraph(self):
        result = self._parse("<p>Hello world</p>")
        children = result["root"]["children"]
        assert len(children) == 1
        assert children[0]["type"] == "paragraph"
        assert children[0]["children"][0]["text"] == "Hello world"

    def test_heading(self):
        result = self._parse("<h2>Title</h2>")
        children = result["root"]["children"]
        assert children[0]["type"] == "heading"
        assert children[0]["tag"] == "h2"

    def test_bold_text(self):
        result = self._parse("<p><strong>bold</strong></p>")
        text_node = result["root"]["children"][0]["children"][0]
        assert text_node["text"] == "bold"
        assert text_node["format"] == 1

    def test_italic_text(self):
        result = self._parse("<p><em>italic</em></p>")
        text_node = result["root"]["children"][0]["children"][0]
        assert text_node["format"] == 2

    def test_bold_italic(self):
        result = self._parse("<p><strong><em>both</em></strong></p>")
        text_node = result["root"]["children"][0]["children"][0]
        assert text_node["format"] == 3

    def test_link(self):
        result = self._parse('<p><a href="https://example.com">click</a></p>')
        link_node = result["root"]["children"][0]["children"][0]
        assert link_node["type"] == "link"
        assert link_node["url"] == "https://example.com"
        assert link_node["children"][0]["text"] == "click"

    def test_ordered_list(self):
        result = self._parse("<ol><li>one</li><li>two</li></ol>")
        list_node = result["root"]["children"][0]
        assert list_node["type"] == "list"
        assert list_node["listType"] == "number"
        assert len(list_node["children"]) == 2

    def test_unordered_list(self):
        result = self._parse("<ul><li>a</li><li>b</li></ul>")
        list_node = result["root"]["children"][0]
        assert list_node["listType"] == "bullet"

    def test_full_digest_structure(self):
        html = """<h2>Summary</h2>
        <ol><li>Item 1</li><li>Item 2</li></ol>
        <h2>Details</h2>
        <h3>1. First</h3>
        <p>Description with <strong>bold</strong> and <em>italic</em>.</p>"""
        result = self._parse(html)
        children = result["root"]["children"]
        types = [c["type"] for c in children]
        assert types == ["heading", "list", "heading", "heading", "paragraph"]

    def test_b_and_i_tags(self):
        result = self._parse("<p><b>bold</b> and <i>italic</i></p>")
        children = result["root"]["children"][0]["children"]
        assert children[0]["format"] == 1
        assert children[2]["format"] == 2

    def test_h1_and_h4(self):
        result = self._parse("<h1>H1</h1><h4>H4</h4>")
        children = result["root"]["children"]
        assert children[0]["tag"] == "h1"
        assert children[1]["tag"] == "h4"


# ============================================================
# _digest_title
# ============================================================

class TestDigestTitle:
    @patch("ghost.datetime")
    def test_no_dates_gives_daily(self, mock_dt):
        mock_dt.now.return_value = datetime(2026, 3, 11, tzinfo=timezone.utc)
        mock_dt.strptime = datetime.strptime
        title = _digest_title()
        assert title == "[Daily] AI Digest — March 11, 2026"

    def test_single_day_range(self):
        title = _digest_title(start_date="2026-03-10", end_date="2026-03-10")
        assert title.startswith("[Daily]")
        assert "March 10, 2026" in title

    def test_weekly_range_6_days(self):
        title = _digest_title(start_date="2026-03-04", end_date="2026-03-10")
        assert title.startswith("[Weekly]")

    def test_weekly_range_7_days(self):
        """Real workflow scenario: start=7 days ago, end=today."""
        title = _digest_title(start_date="2026-03-04", end_date="2026-03-11")
        assert title.startswith("[Weekly]")

    def test_long_range_no_prefix(self):
        title = _digest_title(start_date="2026-01-01", end_date="2026-03-10")
        assert not title.startswith("[Daily]")
        assert not title.startswith("[Weekly]")
        assert title.startswith("AI Digest")

    def test_empty_strings_treated_as_none(self):
        title = _digest_title(start_date="", end_date="")
        assert "[Daily]" in title

    def test_start_date_only(self):
        title = _digest_title(start_date="2026-03-10")
        # Without end_date, span depends on current time — just verify it doesn't crash
        assert "AI Digest" in title


# ============================================================
# GhostError
# ============================================================

class TestGhostError:
    def test_json_error(self):
        err = GhostError(400, '{"errors": [{"message": "bad request"}]}')
        assert "bad request" in str(err)
        assert err.status_code == 400

    def test_invalid_json(self):
        err = GhostError(500, "not json")
        assert "Invalid response" in str(err)

    def test_empty_errors_array(self):
        err = GhostError(400, '{"errors": []}')
        assert err.message == '{"errors": []}'


# ============================================================
# GhostApi
# ============================================================

class TestGhostApi:
    def _mock_api(self):
        """Create a GhostApi with mocked HTTP."""
        with patch("ghost.requests") as mock_requests:
            site_resp = MagicMock()
            site_resp.status_code = 200
            site_resp.json.return_value = {"site": {}}

            newsletters_resp = MagicMock()
            newsletters_resp.status_code = 200
            newsletters_resp.json.return_value = {"newsletters": [{"slug": "default"}]}

            mock_requests.get.side_effect = [site_resp, newsletters_resp]

            api = GhostApi(api_url="https://test.ghost.io", admin_api_key="abc123:" + "aa" * 32)
            return api, mock_requests

    def test_init_bad_key(self):
        with pytest.raises(GhostError):
            GhostApi(api_url="https://test.ghost.io", admin_api_key="badkey")

    def test_init_success(self):
        api, _ = self._mock_api()
        assert api.newsletter_slug == "default"
        assert api.admin_url == "https://test.ghost.io/ghost/api/admin"

    def test_init_no_newsletters(self):
        with patch("ghost.requests") as mock_requests:
            site_resp = MagicMock()
            site_resp.status_code = 200
            site_resp.json.return_value = {"site": {}}

            newsletters_resp = MagicMock()
            newsletters_resp.status_code = 200
            newsletters_resp.json.return_value = {"newsletters": []}

            mock_requests.get.side_effect = [site_resp, newsletters_resp]

            api = GhostApi(api_url="https://test.ghost.io", admin_api_key="abc123:" + "aa" * 32)
            assert api.newsletter_slug is None

    def test_make_token(self):
        api, _ = self._mock_api()
        token = api._make_token()
        assert token.count(".") == 2  # JWT: header.payload.signature

    def test_handle_error(self):
        api, _ = self._mock_api()
        resp = MagicMock()
        resp.status_code = 404
        resp.text = '{"errors": [{"message": "not found"}]}'
        with pytest.raises(GhostError):
            api._handle(resp)

    def test_handle_success(self):
        api, _ = self._mock_api()
        resp = MagicMock()
        resp.status_code = 200
        resp.json.return_value = {"posts": []}
        result = api._handle(resp)
        assert result == {"posts": []}

    @patch("ghost.requests")
    def test_create_post_draft(self, mock_requests):
        # Init responses
        site_resp = MagicMock(status_code=200)
        site_resp.json.return_value = {"site": {}}
        newsletters_resp = MagicMock(status_code=200)
        newsletters_resp.json.return_value = {"newsletters": [{"slug": "default"}]}

        post_resp = MagicMock(status_code=201)
        post_resp.json.return_value = {"posts": [{"id": "1", "title": "Test"}]}

        mock_requests.get.side_effect = [site_resp, newsletters_resp]
        mock_requests.post.return_value = post_resp

        api = GhostApi(api_url="https://test.ghost.io", admin_api_key="abc123:" + "aa" * 32)
        result = api.create_post(title="Test", lexical="{}", status="draft")
        assert result["posts"][0]["id"] == "1"

    @patch("ghost.requests")
    def test_create_post_published_with_newsletter(self, mock_requests):
        site_resp = MagicMock(status_code=200)
        site_resp.json.return_value = {"site": {}}
        newsletters_resp = MagicMock(status_code=200)
        newsletters_resp.json.return_value = {"newsletters": [{"slug": "default"}]}

        draft_resp = MagicMock(status_code=201)
        draft_resp.json.return_value = {"posts": [{"id": "1", "updated_at": "2026-01-01"}]}

        put_resp = MagicMock(status_code=200)
        put_resp.json.return_value = {"posts": [{"id": "1", "url": "https://test.ghost.io/p/1"}]}

        mock_requests.get.side_effect = [site_resp, newsletters_resp]
        mock_requests.post.return_value = draft_resp
        mock_requests.put.return_value = put_resp

        api = GhostApi(api_url="https://test.ghost.io", admin_api_key="abc123:" + "aa" * 32)
        result = api.create_post(title="Test", lexical="{}", status="published", newsletter_slug="default")
        assert result["posts"][0]["url"] == "https://test.ghost.io/p/1"
        mock_requests.put.assert_called_once()
        put_kwargs = mock_requests.put.call_args
        assert put_kwargs.kwargs["params"] == {"newsletter": "default", "email_segment": "all"}


# ============================================================
# cmd_post
# ============================================================

class TestCmdPost:
    def test_missing_file(self, tmp_path):
        import ghost
        ghost.LLM_RESPONSE_TMP = tmp_path / "nonexistent.txt"
        with pytest.raises(SystemExit):
            cmd_post()

    def test_empty_file(self, tmp_path):
        import ghost
        ghost.LLM_RESPONSE_TMP = tmp_path / "empty.txt"
        ghost.LLM_RESPONSE_TMP.write_text("")
        cmd_post()  # should return silently

    def test_missing_ghost_url(self, tmp_path):
        import ghost
        ghost.LLM_RESPONSE_TMP = tmp_path / "response.txt"
        ghost.LLM_RESPONSE_TMP.write_text("<p>content</p>")
        with patch.dict("os.environ", {"GHOST_URL": "", "GHOST_ADMIN_API_KEY": "x:y"}, clear=True):
            with pytest.raises(SystemExit):
                cmd_post()

    def test_missing_admin_key(self, tmp_path):
        import ghost
        ghost.LLM_RESPONSE_TMP = tmp_path / "response.txt"
        ghost.LLM_RESPONSE_TMP.write_text("<p>content</p>")
        with patch.dict("os.environ", {"GHOST_URL": "test.com", "GHOST_ADMIN_API_KEY": ""}, clear=True):
            with pytest.raises(SystemExit):
                cmd_post()

    @patch("ghost.GhostApi")
    def test_publish_success(self, mock_api_cls, tmp_path):
        import ghost
        ghost.LLM_RESPONSE_TMP = tmp_path / "response.txt"
        ghost.LLM_RESPONSE_TMP.write_text("<p>content</p>")

        mock_api = MagicMock()
        mock_api.newsletter_slug = "default"
        mock_api.create_post.return_value = {"posts": [{"id": "1", "url": "https://test.com/p/1", "email": {"status": "sent"}}]}
        mock_api_cls.return_value = mock_api

        with patch.dict("os.environ", {"GHOST_URL": "test.com", "GHOST_ADMIN_API_KEY": "a:bb"}, clear=True):
            cmd_post()
        mock_api.create_post.assert_called_once()

    @patch("ghost.GhostApi")
    def test_publish_no_email_warning(self, mock_api_cls, tmp_path):
        import ghost
        ghost.LLM_RESPONSE_TMP = tmp_path / "response.txt"
        ghost.LLM_RESPONSE_TMP.write_text("<p>content</p>")

        mock_api = MagicMock()
        mock_api.newsletter_slug = "default"
        mock_api.create_post.return_value = {"posts": [{"id": "1", "url": "https://test.com/p/1"}]}
        mock_api_cls.return_value = mock_api

        with patch.dict("os.environ", {"GHOST_URL": "test.com", "GHOST_ADMIN_API_KEY": "a:bb"}, clear=True):
            cmd_post()

    @patch("ghost.GhostApi")
    def test_draft_mode(self, mock_api_cls, tmp_path):
        import ghost
        ghost.LLM_RESPONSE_TMP = tmp_path / "response.txt"
        ghost.LLM_RESPONSE_TMP.write_text("<p>content</p>")

        mock_api = MagicMock()
        mock_api.newsletter_slug = None
        mock_api.create_post.return_value = {"posts": [{"id": "1"}]}
        mock_api_cls.return_value = mock_api

        with patch.dict("os.environ", {"GHOST_URL": "test.com", "GHOST_ADMIN_API_KEY": "a:bb"}, clear=True):
            cmd_post(draft_only=True)

    @patch("ghost.GhostApi")
    def test_custom_title(self, mock_api_cls, tmp_path):
        import ghost
        ghost.LLM_RESPONSE_TMP = tmp_path / "response.txt"
        ghost.LLM_RESPONSE_TMP.write_text("<p>content</p>")

        mock_api = MagicMock()
        mock_api.newsletter_slug = None
        mock_api.create_post.return_value = {"posts": [{"id": "1", "url": "u"}]}
        mock_api_cls.return_value = mock_api

        with patch.dict("os.environ", {"GHOST_URL": "test.com", "GHOST_ADMIN_API_KEY": "a:bb"}, clear=True):
            cmd_post(custom_title="My Title")
        call_kwargs = mock_api.create_post.call_args
        assert call_kwargs[1]["title"] == "My Title" or call_kwargs.kwargs["title"] == "My Title"

    def test_ghost_url_gets_https(self, tmp_path):
        import ghost
        ghost.LLM_RESPONSE_TMP = tmp_path / "response.txt"
        ghost.LLM_RESPONSE_TMP.write_text("<p>content</p>")

        with patch.dict("os.environ", {"GHOST_URL": "test.com", "GHOST_ADMIN_API_KEY": "a:bb"}, clear=True):
            with patch("ghost.GhostApi") as mock_cls:
                mock_api = MagicMock()
                mock_api.newsletter_slug = None
                mock_api.create_post.return_value = {"posts": [{"id": "1", "url": "u"}]}
                mock_cls.return_value = mock_api
                cmd_post()
                mock_cls.assert_called_with(api_url="https://test.com", admin_api_key="a:bb")


# ============================================================
# main (CLI)
# ============================================================

class TestMain:
    def test_no_args_exits(self):
        from ghost import main
        with patch("sys.argv", ["ghost.py"]):
            with pytest.raises(SystemExit):
                main()

    @patch("ghost.cmd_post")
    def test_post_flag(self, mock_cmd):
        from ghost import main
        with patch("sys.argv", ["ghost.py", "--post"]):
            main()
        mock_cmd.assert_called_once()

    @patch("ghost.cmd_post")
    def test_post_with_all_flags(self, mock_cmd):
        from ghost import main
        with patch("sys.argv", ["ghost.py", "--post", "--draft", "--title", "T", "--start-date", "2026-01-01", "--end-date", "2026-01-02"]):
            main()
        mock_cmd.assert_called_once_with(draft_only=True, custom_title="T", start_date="2026-01-01", end_date="2026-01-02")
