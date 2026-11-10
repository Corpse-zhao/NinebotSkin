#import "NBManager.h"

// v0.1.0：零 %hook 设计 —— 全部功能在 NBManager 运行时完成，
// 避免 Logos 对不存在类/方法静默丢弃的整类故障。
%ctor {
    @autoreleasepool {
        [[NBManager shared] boot];
    }
}
