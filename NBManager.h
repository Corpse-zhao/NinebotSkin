#import <Foundation/Foundation.h>

#define NB_VERSION @"0.1.10"

@interface NBManager : NSObject
+ (instancetype)shared;
- (void)boot;
@end
