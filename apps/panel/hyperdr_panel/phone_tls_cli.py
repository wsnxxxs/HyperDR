"""Compatibility entry point for Setup-HTTPS.bat using the in-app CA manager."""
from __future__ import annotations

import argparse
from pathlib import Path

from . import phone_tls
from .server import lan_addresses


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--force", action="store_true", help="Renew the server certificate using the existing root")
    args = parser.parse_args()
    addresses = lan_addresses()
    if not addresses:
        print("请先连接 Wi-Fi 或以太网，再运行证书配置。")
        return 1
    state = phone_tls.prepare(addresses, force=args.force)
    if not state["ready"]:
        print(state.get("error") or "证书未能准备完成。")
        return 1
    if not state["rootAvailable"]:
        print("自定义 HTTPS 证书已就绪，请按证书提供方的说明配置手机信任。")
        return 0
    target = Path(state["certificatePath"]).parent / "HyperDR-rootCA.crt"
    target.write_bytes(phone_tls.root_certificate())
    print("本机证书已准备好。未修改电脑的系统信任设置。")
    print(f"公开根证书：{target}")
    print("打开 HyperDR → 手机工作台 → 设置另一部手机，扫码按步骤安装并信任证书。")
    print("手机信任只需首次设置；地址变化与续期继续使用同一根证书。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
