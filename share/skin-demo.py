# 注释是灰色斜体。下面每一类语法都走当前主题自己的颜色。
from dataclasses import dataclass


@dataclass
class Palette:
    """类型名、字符串、数字分属三种颜色。"""

    name: str = "omacosy"
    steps: int = 4


def mix(base: str, accent: str, amount: float) -> str:
    if amount >= 0.9 and base != accent:
        return accent
    return base


THEME = "snow-black"
print(mix(Palette.name, "rose", 0.42))
