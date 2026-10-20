#import <Foundation/Foundation.h>

// 防篡改壳已停用。
//
// 原因：本项目就是为「越狱设备 + 游戏内注入按钮」设计的，
// 反注入检测（扫描 dyld 镜像里的 substrate/substitute/frida 等名字）会把自己人杀掉 ——
// rootless 越狱的注入加载器会进入所有进程，包括本 App 自己，
// 结果就是 App 一启动就弹「检测到非法注入」然后 exit(0)，
// 游戏内点保存 → 拉起本 App 兜底 → 立刻被杀，表现为「闪退」。
//
// 反调试 / 反重签 / 沙盒检测一并停用：这套检查只在「防外人破解」时有意义，
// 对自用工具只有副作用。历史版本见 git（文件曾含四道完整检查）。
@implementation RetroAntiTamper
@end
