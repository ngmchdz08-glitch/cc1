#import "VcamAppDelegate.h"
#import "VcamRootViewController.h"

@implementation VcamAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [[VcamRootViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}
@end
