# -*- coding: utf-8 -*-
import os

def patch_file(file_path):
    if not os.path.exists(file_path):
        print(f"File {file_path} not found")
        return

    with open(file_path, 'r', encoding='utf-8') as f:
        content = f.read()

    # Technical Localization for Disk/NAS
    replacements = {
        'Disk status: ': '磁盘状态：',
        'Disk format: ': '磁盘格式：',
        'Read only': '只读',
        'Read and write': '读写',
        'Partition Information - ': '分区信息 - ',
        ' (System disk)': ' (系统盘)',
        'WARNING: This operation will initialize': '警告：此操作将初始化',
        'hard disk and create partitions, please operate with caution': '硬盘并创建分区，请谨慎操作',
        'Your system space is insufficient. It is detected that your docker root directory is located on system root directory': '系统空间不足。检测到您的 Docker 根目录位于系统分区上',
        'which may affect the normal operation of the system. Recommended to use Docker migration wizard': '这可能会影响系统正常运行。建议使用 Docker 迁移向导',
        'migrate docker root directory to an external hard disk.': '将 Docker 目录迁移到外部硬盘。',
        
        # Docker Migration Wizard
        'Docker \u79fb\u690d': 'Docker 迁移向导', # Docker 移植
        'Replace directory': '替换目录',
        'Do not overwrite the target path, only modify docker directory to target path': '不覆盖目标路径，仅将 Docker 目录修改为目标路径',
        
        # Actions
        'Finish': '完成',
        'Next': '下一步',
        'Cancel': '取消',
        'Startup failed': '启动失败',
        
        # Docker card
        'View docker information': '查看 Docker 信息',
        
        # More specific Disk strings found in research
        'Disk status: Read only': '磁盘状态：只读',
        'Disk status: Read and write': '磁盘状态：读写',
        'Disk format: ': '磁盘格式：'
    }

    # Apply replacements
    new_content = content
    for old, new in replacements.items():
        new_content = new_content.replace(old, new)

    # Specific fix for the long string on line 4877 which might be broken into parts
    old_long = "Your system space is insufficient. It is detected that your docker root directory is located on system root directory, which may affect the normal operation of the system. Recommended to use Docker migration wizard to migrate docker root directory to an external hard disk."
    new_long = "系统空间不足。检测到您的 Docker 根目录位于系统分区上，这可能会影响系统正常运行。建议使用 Docker 迁移向导将 Docker 目录迁移到外部硬盘。"
    new_content = new_content.replace(old_long, new_long)

    if new_content != content:
        with open(file_path, 'w', encoding='utf-8') as f:
            f.write(new_content)
        print(f"Patched {file_path} successfully")
    else:
        print(f"No changes made to {file_path}")

if __name__ == "__main__":
    patch_file("htdocs/luci-static/dashboard/index.js")
    # Also patch main.htm if there are any lingering strings
    patch_file("luasrc/view/dashboard/main.htm")
