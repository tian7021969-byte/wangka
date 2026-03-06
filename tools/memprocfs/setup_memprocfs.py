"""
setup_memprocfs.py - MemProcFS 自动部署脚本
从 GitHub 下载最新 Windows x64 发行版，解压关键 DLL 到项目根目录
"""
import os
import sys
import json
import zipfile
import shutil
import tempfile
import urllib.request
import urllib.error
import re

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
TOOLS_DIR = os.path.dirname(os.path.abspath(__file__))

GITHUB_API_URL = "https://api.github.com/repos/ufrisk/MemProcFS/releases/latest"

REQUIRED_FILES = [
    'vmm.dll',
    'leechcore.dll',
    'FTD3XX.dll',
    'info.db',
]


def _build_headers():
    """构建 HTTP 请求头，支持 GITHUB_TOKEN 绕过限流"""
    headers = {'User-Agent': 'MemProcFS-Setup'}
    token = os.environ.get('GITHUB_TOKEN', '')
    if token:
        headers['Authorization'] = f'token {token}'
        print("  (使用 GITHUB_TOKEN 认证)")
    return headers


def get_latest_release():
    """查询 GitHub API 获取最新 release 信息，限流时自动回退到 HTML 解析"""
    print("[1/4] 查询 MemProcFS 最新版本...")
    headers = _build_headers()
    req = urllib.request.Request(GITHUB_API_URL, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.loads(resp.read().decode('utf-8'))
        tag = data.get('tag_name', 'unknown')
        print(f"  最新版本: {tag}")
        return data
    except urllib.error.HTTPError as e:
        if e.code == 403:
            print("  [!] GitHub API 限流，切换到备用方案...")
            return _fallback_from_html()
        raise


def _fallback_from_html():
    """备用方案: 通过重定向获取版本号，再从 expanded_assets 页面解析下载链接"""
    releases_url = "https://github.com/ufrisk/MemProcFS/releases/latest"
    print(f"  正在获取最新版本号...")
    req = urllib.request.Request(releases_url, headers={'User-Agent': 'MemProcFS-Setup'})
    with urllib.request.urlopen(req, timeout=30) as resp:
        final_url = resp.url

    tag_match = re.search(r'/releases/tag/([^"/?]+)', final_url)
    if not tag_match:
        print(f"  [!] 无法从重定向 URL 解析版本号: {final_url}")
        sys.exit(1)

    tag = tag_match.group(1)
    print(f"  最新版本: {tag}")

    # 从 expanded_assets 页面获取下载链接列表
    expanded_url = f"https://github.com/ufrisk/MemProcFS/releases/expanded_assets/{tag}"
    print(f"  正在获取文件列表...")
    req2 = urllib.request.Request(expanded_url, headers={'User-Agent': 'MemProcFS-Setup'})
    try:
        with urllib.request.urlopen(req2, timeout=30) as resp2:
            html = resp2.read().decode('utf-8', errors='ignore')
        pattern = r'href="(/ufrisk/MemProcFS/releases/download/[^"]+\.zip)"'
        matches = re.findall(pattern, html)
    except Exception:
        matches = []

    assets = []
    for m in matches:
        full_url = f"https://github.com{m}"
        filename = m.split('/')[-1]
        assets.append({
            'name': filename,
            'browser_download_url': full_url,
            'size': 0,
        })

    # 如果仍未找到，用已知命名规则构造候选 URL
    if not assets:
        print("  [!] 页面解析失败，使用已知命名规则尝试直接下载...")
        ver = tag.lstrip('v')  # v5.17 -> 5.17
        candidates = [
            f"MemProcFS_files_and_binaries_{tag}-win_x64.zip",
            f"MemProcFS_files_and_binaries_v{ver}-win_x64.zip",
        ]
        for name in candidates:
            url = f"https://github.com/ufrisk/MemProcFS/releases/download/{tag}/{name}"
            try:
                test_req = urllib.request.Request(url, method='HEAD',
                                                  headers={'User-Agent': 'MemProcFS-Setup'})
                with urllib.request.urlopen(test_req, timeout=10):
                    pass
                print(f"  命中: {name}")
                assets.append({
                    'name': name,
                    'browser_download_url': url,
                    'size': 0,
                })
                break
            except Exception:
                continue

    if not assets:
        print(f"  [!] 所有自动方式均失败")
        print(f"  请手动下载: {releases_url}")
        print(f"  将 zip 放到: {TOOLS_DIR}")
        sys.exit(1)

    print(f"  找到 {len(assets)} 个文件")
    return {'tag_name': tag, 'assets': assets}


def find_win_x64_asset(release_data):
    """从 release assets 中找到 Windows x64 压缩包"""
    assets = release_data.get('assets', [])
    for asset in assets:
        name = asset['name'].lower()
        if 'win' in name and 'x64' in name and name.endswith('.zip'):
            size_str = f" ({asset['size'] / 1024 / 1024:.1f} MB)" if asset.get('size') else ""
            print(f"  目标文件: {asset['name']}{size_str}")
            return asset

    for asset in assets:
        name = asset['name'].lower()
        if 'win' in name and name.endswith('.zip'):
            size_str = f" ({asset['size'] / 1024 / 1024:.1f} MB)" if asset.get('size') else ""
            print(f"  备选文件: {asset['name']}{size_str}")
            return asset

    print("  [!] 未找到 Windows x64 压缩包，可用文件:")
    for a in assets:
        print(f"      - {a['name']}")
    sys.exit(1)


def download_asset(asset):
    """下载 release 压缩包"""
    url = asset['browser_download_url']
    filename = asset['name']
    filepath = os.path.join(TOOLS_DIR, filename)

    if os.path.exists(filepath):
        print(f"  已存在缓存: {filename}，跳过下载")
        return filepath

    print(f"[2/4] 下载 {filename}...")
    print(f"  URL: {url}")

    req = urllib.request.Request(url, headers={'User-Agent': 'MemProcFS-Setup'})
    with urllib.request.urlopen(req, timeout=120) as resp:
        total = int(resp.headers.get('Content-Length', 0))
        downloaded = 0
        chunk_size = 1024 * 256

        with open(filepath, 'wb') as f:
            while True:
                chunk = resp.read(chunk_size)
                if not chunk:
                    break
                f.write(chunk)
                downloaded += len(chunk)
                if total > 0:
                    pct = downloaded / total * 100
                    done = int(pct // 2)
                    bar = '#' * done + '-' * (50 - done)
                    print(f"\r  [{bar}] {pct:.0f}% ({downloaded // 1024 // 1024}MB/{total // 1024 // 1024}MB)", end='', flush=True)

    print(f"\n  下载完成: {filepath}")
    return filepath


def extract_required_files(zip_path):
    """从压缩包中提取关键文件到项目根目录"""
    print(f"[3/4] 解压关键文件到项目根目录: {PROJECT_ROOT}")

    extracted = []
    with zipfile.ZipFile(zip_path, 'r') as zf:
        all_names = zf.namelist()

        for required in REQUIRED_FILES:
            found = False
            req_lower = required.lower()
            for name in all_names:
                basename = os.path.basename(name).lower()
                if basename == req_lower:
                    target_path = os.path.join(PROJECT_ROOT, required)
                    with zf.open(name) as src, open(target_path, 'wb') as dst:
                        shutil.copyfileobj(src, dst)
                    size = os.path.getsize(target_path)
                    print(f"  {required:20s} -> {target_path} ({size:,} bytes)")
                    extracted.append(required)
                    found = True
                    break
            if not found:
                print(f"  [!] {required:20s} -> 未在压缩包中找到")

    # 同时解压完整包到 tools/memprocfs 备用
    full_extract_dir = os.path.join(TOOLS_DIR, 'dist')
    if not os.path.exists(full_extract_dir):
        print(f"\n  解压完整包到: {full_extract_dir}")
        with zipfile.ZipFile(zip_path, 'r') as zf:
            zf.extractall(full_extract_dir)
        print(f"  完整解压完成")

    return extracted


def verify_files():
    """验证关键文件是否就位"""
    print(f"[4/4] 验证文件...")
    all_ok = True
    for f in REQUIRED_FILES:
        path = os.path.join(PROJECT_ROOT, f)
        if os.path.exists(path):
            size = os.path.getsize(path)
            print(f"  [OK] {f:20s} ({size:,} bytes)")
        else:
            print(f"  [!!] {f:20s} 缺失!")
            all_ok = False
    return all_ok


def main():
    print("=" * 55)
    print("  MemProcFS 自动部署工具")
    print(f"  项目根目录: {PROJECT_ROOT}")
    print("=" * 55)
    print()

    release = get_latest_release()
    asset = find_win_x64_asset(release)
    zip_path = download_asset(asset)
    extracted = extract_required_files(zip_path)

    print()
    ok = verify_files()

    print()
    if ok:
        print("=" * 55)
        print("  部署成功! 所有关键文件已就位。")
        print("  可运行 check_dma.py 测试硬件连接。")
        print("=" * 55)
    else:
        print("=" * 55)
        print("  [!] 部分文件缺失，请检查压缩包内容。")
        print(f"  完整文件已解压到: {os.path.join(TOOLS_DIR, 'dist')}")
        print("  请手动复制缺失文件到项目根目录。")
        print("=" * 55)
        sys.exit(1)


if __name__ == '__main__':
    main()
