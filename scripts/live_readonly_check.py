#!/usr/bin/env python3
"""Anonymous live-contract diagnostics. Fixed GET allowlist; never loads login data."""
import argparse
import json
import urllib.error
import urllib.parse
import urllib.request

ROUTES = {
    "giftConfig": ("/xlive/web-room/v1/giftPanel/giftConfig", {"platform": "pc"}),
    "roomGiftList": ("/xlive/web-room/v1/giftPanel/roomGiftList", {"platform": "pc", "area_parent_id": "0", "area_id": "0"}),
    "dmConfig": ("/xlive/web-room/v1/dM/GetDMConfigByGroup", {}),
    "superChatList": ("/av/v1/SuperChat/getMessageList", {}),
    "lotteryInfo": ("/xlive/lottery-interface/v1/lottery/getLotteryInfoWeb", {}),
}


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise urllib.error.HTTPError(req.full_url, code, "Redirect refused", headers, fp)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--room", type=int, default=6)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    if args.room <= 0:
        parser.error("room must be positive")
    opener = urllib.request.build_opener(NoRedirect())
    failed = False
    for name, (path, defaults) in ROUTES.items():
        params = dict(defaults)
        params["roomid" if name == "lotteryInfo" else "room_id"] = str(args.room)
        url = "https://api.live.bilibili.com" + path + "?" + urllib.parse.urlencode(params)
        if args.dry_run:
            print(json.dumps({"route": name, "method": "GET", "url": url}))
            continue
        request = urllib.request.Request(url, method="GET", headers={
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/18.0 Safari/605.1.15",
            "Origin": "https://live.bilibili.com", "Referer": "https://live.bilibili.com/",
        })
        try:
            with opener.open(request, timeout=15) as response:
                raw = response.read(4 * 1024 * 1024 + 1)
                if len(raw) > 4 * 1024 * 1024:
                    raise ValueError("response exceeds local limit")
                root = json.loads(raw)
                data = root.get("data")
                # Report only public structure, never names, chat text or account records.
                result = {"route": name, "code": root.get("code"), "data_keys": sorted(data) if isinstance(data, dict) else [],
                          "list_counts": {key: len(value) for key, value in data.items() if isinstance(value, list)} if isinstance(data, dict) else {}}
                print(json.dumps(result, ensure_ascii=False))
                failed |= root.get("code") != 0
                if root.get("code") == -352:
                    break
        except (urllib.error.URLError, ValueError, TimeoutError) as error:
            print(json.dumps({"route": name, "error_type": type(error).__name__}))
            failed = True
            if isinstance(error, urllib.error.HTTPError) and error.code in (412, 429):
                break
    return int(failed)


if __name__ == "__main__":
    raise SystemExit(main())
