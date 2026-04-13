# -*- coding: utf-8 -*-
import os

def patch_file(file_path):
    if not os.path.exists(file_path):
        print(f"File {file_path} not found")
        return

    with open(file_path, 'r', encoding='utf-8') as f:
        content = f.read()

    # Technical Localization for v1.3.1
    replacements = {
        '"\u5185\u7f51\u6d4b\u901f"': '"内网配置"', # Intranet Speed Test -> Intranet Config
        'IPv4 Address': 'IPv4 地址',
        'IPv4 Subnet mask': 'IPv4 子网掩码',
        'Save': '保存',
        'Cancel': '取消',
        'Not Installed': '未安装',
        'not installed': '未安装'
    }

    # Apply replacements
    new_content = content
    for old, new in replacements.items():
        new_content = new_content.replace(old, new)

    if new_content != content:
        with open(file_path, 'w', encoding='utf-8') as f:
            f.write(new_content)
        print(f"Patched {file_path} successfully")
    else:
        print(f"No changes made to {file_path}")

if __name__ == "__main__":
    patch_file("htdocs/luci-static/dashboard/index.js")
