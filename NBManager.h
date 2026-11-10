#import <Foundation/Foundation.h>

#define NB_VERSION @"0.1.2"

@interface NBManager : NSObject
+ (instancetype)shared;
- (void)boot;
@end
