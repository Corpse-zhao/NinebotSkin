#import <Foundation/Foundation.h>

#define NB_VERSION @"0.2.11"

@interface NBManager : NSObject
+ (instancetype)shared;
- (void)boot;
@end
