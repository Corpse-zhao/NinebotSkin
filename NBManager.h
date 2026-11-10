#import <Foundation/Foundation.h>

#define NB_VERSION @"0.1.5"

@interface NBManager : NSObject
+ (instancetype)shared;
- (void)boot;
@end
