// AntiBank.x — Anti-jailbreak detection
// Inject vào TẤT CẢ user-space processes nhưng chặn ngân hàng đúng cách
// Không inject UIKit global nữa — quá rộng → crash

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <sys/stat.h>
#import <sys/types.h>

// ─────────────────────────────────────────────
// Danh sách path bị che — mirror đúng VCNext behavior
// ─────────────────────────────────────────────
static BOOL vcam_isSensitivePath(NSString *path) {
    if (!path) return NO;
    static NSArray *blockedSubstrings;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        blockedSubstrings = @[
            @"/var/jb",
            @"/var/lib/dpkg",
            @"/private/var/lib/cydia",
            @"Cydia",
            @"Sileo",
            @"Zebra",
            @"Vcam_Mch",
            @"substrate",
            @"MobileSubstrate",
            @"ElleKit",
            @"cynject",
            @"inject_criticald",
        ];
    });
    for (NSString *sub in blockedSubstrings) {
        if ([path rangeOfString:sub options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
    }
    return NO;
}

// ─────────────────────────────────────────────
// NSFileManager — file existence check
// ─────────────────────────────────────────────
%hook NSFileManager

- (BOOL)fileExistsAtPath:(NSString *)path {
    if (vcam_isSensitivePath(path)) return NO;
    return %orig;
}

- (BOOL)fileExistsAtPath:(NSString *)path isDirectory:(BOOL *)isDirectory {
    if (vcam_isSensitivePath(path)) {
        if (isDirectory) *isDirectory = NO;
        return NO;
    }
    return %orig;
}

- (NSArray *)contentsOfDirectoryAtPath:(NSString *)path error:(NSError **)error {
    if (vcam_isSensitivePath(path)) {
        if (error) *error = nil;
        return @[];
    }
    return %orig;
}

%end

// ─────────────────────────────────────────────
// Hook C stat — dùng %hookf
// ─────────────────────────────────────────────
%hookf(int, stat, const char *cpath, struct stat *buf) {
    if (cpath) {
        NSString *path = [NSString stringWithUTF8String:cpath];
        if (vcam_isSensitivePath(path)) return -1;
    }
    return %orig(cpath, buf);
}

%hookf(int, lstat, const char *cpath, struct stat *buf) {
    if (cpath) {
        NSString *path = [NSString stringWithUTF8String:cpath];
        if (vcam_isSensitivePath(path)) return -1;
    }
    return %orig(cpath, buf);
}

%hookf(int, access, const char *cpath, int mode) {
    if (cpath) {
        NSString *path = [NSString stringWithUTF8String:cpath];
        if (vcam_isSensitivePath(path)) return -1;
    }
    return %orig(cpath, mode);
}

// ─────────────────────────────────────────────
// ptrace bypass — chống anti-debug
// ─────────────────────────────────────────────
extern int ptrace(int request, pid_t pid, caddr_t addr, int data);

%hookf(int, ptrace, int request, pid_t pid, caddr_t addr, int data) {
    if (request == 31) return 0; // PT_DENY_ATTACH → bypass
    return %orig(request, pid, addr, data);
}

// ─────────────────────────────────────────────
// NSProcessInfo — ẩn tên tweak trong environment
// ─────────────────────────────────────────────
%hook NSProcessInfo

- (NSDictionary<NSString *, NSString *> *)environment {
    NSMutableDictionary *env = [%orig mutableCopy];
    // Xóa các biến môi trường tố cáo substrate inject
    [env removeObjectForKey:@"DYLD_INSERT_LIBRARIES"];
    [env removeObjectForKey:@"_MSSafeMode"];
    return [env copy];
}

%end

// ─────────────────────────────────────────────
// Constructor — inject vào MỌI process (trừ system daemons)
// ─────────────────────────────────────────────
%ctor {
    NSString *proc = [[NSProcessInfo processInfo] processName];
    // Bỏ qua kernel/launchd và daemon hệ thống để không crash
    NSArray *skip = @[@"launchd", @"configd", @"powerd", @"syslogd", @"mediaserverd"];
    if ([skip containsObject:proc]) return;
    
    %init;
    NSLog(@"[Vcam_Mch/AntiBank] Loaded in: %@", proc);
}
