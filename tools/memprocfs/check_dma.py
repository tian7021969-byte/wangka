"""
check_dma.py - DMA 硬件连接测试
通过 MemProcFS 加载 vmm.dll 并尝试连接 FPGA DMA 设备
"""
import os
import sys

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
SYMBOLS_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), '_symbols')

def check_dlls():
    """检查关键 DLL 是否存在"""
    required = ['vmm.dll', 'leechcore.dll', 'FTD3XX.dll']
    missing = []
    for dll in required:
        path = os.path.join(PROJECT_ROOT, dll)
        if os.path.exists(path):
            size = os.path.getsize(path)
            print(f"  [OK] {dll:20s} ({size:,} bytes)")
        else:
            print(f"  [!!] {dll:20s} 缺失!")
            missing.append(dll)
    return missing


def test_dma_connection():
    """尝试通过 FPGA 设备连接目标机器"""
    try:
        import memprocfs
    except ImportError:
        print("[!] memprocfs 模块未安装，请先运行:")
        print("    .venv\\Scripts\\pip install memprocfs")
        return False

    os.makedirs(SYMBOLS_DIR, exist_ok=True)

    print("\n[2/2] 初始化 MemProcFS (FPGA DMA 模式)...")
    print(f"  vmm.dll 搜索路径: {PROJECT_ROOT}")
    print(f"  符号缓存路径:     {SYMBOLS_DIR}")

    try:
        vmm = memprocfs.Vmm(['-device', 'fpga', '-printf', '-symbolpath', SYMBOLS_DIR])
    except Exception as e:
        err = str(e)
        if 'device' in err.lower() or 'fpga' in err.lower():
            print(f"\n  [!] FPGA 设备未检测到: {err}")
            print("  请确认:")
            print("    1. DMA 硬件已插入并连接目标机器")
            print("    2. FTD3XX 驱动已正确安装")
            print("    3. 目标机器已开机")
        elif 'vmm.dll' in err.lower() or 'load' in err.lower():
            print(f"\n  [!] vmm.dll 加载失败: {err}")
            print(f"  请先运行 setup_memprocfs.py 部署 DLL 文件")
        else:
            print(f"\n  [!] 初始化失败: {err}")
        return False

    print("  [OK] MemProcFS 初始化成功!")
    print(f"  内核版本: {vmm.kernel.build}")

    # 列出前 10 个进程验证连接
    print("\n  目标机器进程列表 (前10个):")
    print(f"  {'PID':>8s}  {'进程名':<30s}")
    print(f"  {'-'*8}  {'-'*30}")
    for i, process in enumerate(vmm.process_list()):
        if i >= 10:
            remaining = len(vmm.process_list()) - 10
            print(f"  ... 还有 {remaining} 个进程")
            break
        print(f"  {process.pid:>8d}  {process.name:<30s}")

    vmm.close()
    print("\n  [OK] DMA 连接测试完成，一切正常!")
    return True


def main():
    print("=" * 55)
    print("  MemProcFS DMA 硬件连接测试")
    print("=" * 55)
    print()

    # 将项目根目录加入 DLL 搜索路径
    os.add_dll_directory(PROJECT_ROOT)
    os.environ['PATH'] = PROJECT_ROOT + os.pathsep + os.environ.get('PATH', '')

    print("[1/2] 检查 DLL 文件...")
    missing = check_dlls()
    if missing:
        print(f"\n  [!] 缺少关键文件: {', '.join(missing)}")
        print("  请先运行: python setup_memprocfs.py")
        sys.exit(1)

    test_dma_connection()


if __name__ == '__main__':
    main()
