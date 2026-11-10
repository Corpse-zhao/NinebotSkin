#import <Foundation/Foundation.h>

#define NB_VERSION @"0.2.3"

@interface NBManager : NSObject
+ (instancetype)shared;
- (void)boot;
@end
