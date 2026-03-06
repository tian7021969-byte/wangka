"""
offset_manager.py
游戏内存偏移量集中管理模块。
支持从 JSON 文件热加载，属性式访问 (manager.client.entity_list)。
"""

from __future__ import annotations
import json
import os
import time
import logging
from typing import Any

log = logging.getLogger(__name__)


class _OffsetNode:
    """递归节点——将嵌套 dict 映射为属性链。"""

    def __init__(self, data: dict):
        self._data = data

    def __getattr__(self, name: str) -> Any:
        try:
            val = self._data[name]
        except KeyError:
            raise AttributeError(f"偏移量 '{name}' 不存在，请检查 JSON 配置")
        if isinstance(val, dict):
            return _OffsetNode(val)
        return val

    def __repr__(self):
        return f"OffsetNode({self._data})"

    def keys(self):
        return self._data.keys()


class OffsetManager:
    """
    偏移量管理器。
    使用方式:
        mgr = OffsetManager("offsets.json")
        entity_list_addr = base + mgr.client.entity_list
        view_matrix_addr = base + mgr.client.view_matrix
    """

    DEFAULTS: dict = {
        "client": {
            "entity_list":    0x18C2D58,
            "view_matrix":    0x1820140,
            "local_player":   0x1887E28,
            "force_jump":     0x1736B00,
        },
        "entity": {
            "health":         0x344,
            "team":           0x3E3,
            "position":       0xD50,
            "eye_position":   0x1094,
            "dormant":        0xE7,
            "bone_matrix":    0x80,
        },
        "screen": {
            "width":  2560,
            "height": 1440,
        },
    }

    def __init__(self, config_path: str | None = None):
        self._path: str | None = config_path
        self._mtime: float = 0.0
        self._offsets: dict = {}
        if config_path and os.path.isfile(config_path):
            self._load_file(config_path)
        else:
            log.info("未找到偏移量文件，使用内置默认值")
            self._offsets = self.DEFAULTS.copy()

    # ------------------------------------------------------------------
    #  文件 I/O
    # ------------------------------------------------------------------
    def _load_file(self, path: str):
        with open(path, "r", encoding="utf-8") as f:
            self._offsets = json.load(f)
        self._mtime = os.path.getmtime(path)
        log.info("已加载偏移量: %s (%d 个顶层键)", path, len(self._offsets))

    def reload_if_changed(self) -> bool:
        """如果 JSON 文件在磁盘上被修改过，则重新加载。返回是否发生了重载。"""
        if not self._path or not os.path.isfile(self._path):
            return False
        mt = os.path.getmtime(self._path)
        if mt > self._mtime:
            self._load_file(self._path)
            return True
        return False

    def save(self, path: str | None = None):
        """将当前偏移量写回 JSON 文件。"""
        out = path or self._path
        if not out:
            raise ValueError("未指定保存路径")
        with open(out, "w", encoding="utf-8") as f:
            json.dump(self._offsets, f, indent=2, ensure_ascii=False)
        log.info("偏移量已保存: %s", out)

    # ------------------------------------------------------------------
    #  属性式访问
    # ------------------------------------------------------------------
    def __getattr__(self, name: str) -> Any:
        if name.startswith("_"):
            raise AttributeError(name)
        try:
            val = self._offsets[name]
        except KeyError:
            raise AttributeError(f"偏移量分组 '{name}' 不存在")
        if isinstance(val, dict):
            return _OffsetNode(val)
        return val

    def get(self, dotpath: str, default: Any = 0) -> Any:
        """
        点号分隔路径访问:  mgr.get("entity.health", 0x344)
        """
        node = self._offsets
        for part in dotpath.split("."):
            if isinstance(node, dict) and part in node:
                node = node[part]
            else:
                return default
        return node

    def set(self, dotpath: str, value: Any):
        """运行时更新偏移量:  mgr.set("entity.health", 0x350)"""
        parts = dotpath.split(".")
        node = self._offsets
        for part in parts[:-1]:
            node = node.setdefault(part, {})
        node[parts[-1]] = value

    def dump(self) -> dict:
        """返回完整偏移量快照。"""
        return self._offsets.copy()
