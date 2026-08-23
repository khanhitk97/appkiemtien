#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <sys/time.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <mach/mach_time.h>
#import <os/lock.h>
#import "fishhook.h"

// ==========================================
// 1. SPEED ENGINE VỚI KHÓA AN TOÀN THREAD
// ==========================================
static float speed_factor = 1.0f; // Mặc định chạy 1x
static os_unfair_lock speed_lock = OS_UNFAIR_LOCK_INIT;

static int (*orig_gettimeofday)(struct timeval *tv, struct timezone *tz) = NULL;
static CFAbsoluteTime (*orig_CFAbsoluteTimeGetCurrent)(void) = NULL;
static uint64_t (*orig_mach_absolute_time)(void) = NULL;

static struct timeval last_real_tv = {0, 0}, fake_tv = {0, 0};
static CFAbsoluteTime last_real_cf = 0, fake_cf = 0;
static uint64_t last_real_mach = 0, fake_mach = 0;

#ifdef __cplusplus
extern "C" {
#endif

void set_speed_factor(float factor) {
    os_unfair_lock_lock(&speed_lock);
    speed_factor = factor;
    
    // Nếu chuyển về 1x -> Reset toàn bộ mốc giả lập
    if (factor == 1.0f) {
        last_real_tv = (struct timeval){0, 0};
        fake_tv = (struct timeval){0, 0};
        last_real_cf = 0;
        fake_cf = 0;
        last_real_mach = 0;
        fake_mach = 0;
    }
    os_unfair_lock_unlock(&speed_lock);
}

#ifdef __cplusplus
}
#endif

// Hook 1: gettimeofday
int my_gettimeofday(struct timeval *tv, struct timezone *tz) {
    int ret = orig_gettimeofday(tv, tz);
    if (ret != 0 || !tv) return ret;

    os_unfair_lock_lock(&speed_lock);
    if (speed_factor == 1.0f) {
        os_unfair_lock_unlock(&speed_lock);
        return ret;
    }

    if (last_real_tv.tv_sec == 0) {
        last_real_tv = *tv;
        fake_tv = *tv;
    } else {
        double delta = (tv->tv_sec - last_real_tv.tv_sec) + (tv->tv_usec - last_real_tv.tv_usec) / 1e6;
        double fake_delta = delta * speed_factor;
        long sec_add = (long)fake_delta;
        long usec_add = (long)((fake_delta - sec_add) * 1e6);

        fake_tv.tv_sec += sec_add;
        fake_tv.tv_usec += usec_add;
        if (fake_tv.tv_usec >= 1000000) {
            fake_tv.tv_sec += 1;
            fake_tv.tv_usec -= 1000000;
        }
        last_real_tv = *tv;
    }
    *tv = fake_tv;
    os_unfair_lock_unlock(&speed_lock);
    return ret;
}

// Hook 2: CFAbsoluteTimeGetCurrent
CFAbsoluteTime my_CFAbsoluteTimeGetCurrent(void) {
    CFAbsoluteTime real_now = orig_CFAbsoluteTimeGetCurrent();

    os_unfair_lock_lock(&speed_lock);
    if (speed_factor == 1.0f) {
        os_unfair_lock_unlock(&speed_lock);
        return real_now;
    }

    if (last_real_cf == 0) {
        last_real_cf = real_now;
        fake_cf = real_now;
    } else {
        fake_cf += (real_now - last_real_cf) * speed_factor;
        last_real_cf = real_now;
    }
    CFAbsoluteTime result = fake_cf;
    os_unfair_lock_unlock(&speed_lock);
    return result;
}

// Hook 3: mach_absolute_time
uint64_t my_mach_absolute_time(void) {
    uint64_t real_now = orig_mach_absolute_time();

    os_unfair_lock_lock(&speed_lock);
    if (speed_factor == 1.0f) {
        os_unfair_lock_unlock(&speed_lock);
        return real_now;
    }

    if (last_real_mach == 0) {
        last_real_mach = real_now;
        fake_mach = real_now;
    } else {
        fake_mach += (uint64_t)((real_now - last_real_mach) * speed_factor);
        last_real_mach = real_now;
    }
    uint64_t result = fake_mach;
    os_unfair_lock_unlock(&speed_lock);
    return result;
}

// ==========================================
// 2. TỰ ĐỘNG KÍCH HOẠT X5 TẠI GIÂY THỨ 4
// ==========================================
static dispatch_source_t autoSpeedTimer = nil;

@interface OrderSpeedTrigger : NSObject
+ (void)startAutoSpeedSequence;
+ (void)stopAndResetSpeed;
+ (BOOL)isMainListScreen:(UIView *)view;
@end

@implementation OrderSpeedTrigger

+ (BOOL)isMainListScreen:(UIView *)view {
    NSString *accessibility = [view.accessibilityLabel lowercaseString];
    if (accessibility && [accessibility isEqualToString:@"đơn hàng"]) {
        return YES;
    }

    if ([view respondsToSelector:@selector(text)]) {
        NSString *text = [((UILabel *)view).text lowercaseString];
        if (text && [text isEqualToString:@"đơn hàng"]) {
            return YES;
        }
    }

    for (UIView *subview in view.subviews) {
        if ([self isMainListScreen:subview]) {
            return YES;
        }
    }
    return NO;
}

+ (void)stopAndResetSpeed {
    if (autoSpeedTimer) {
        dispatch_source_cancel(autoSpeedTimer);
        autoSpeedTimer = nil;
    }
    set_speed_factor(1.0f);
}

+ (void)startAutoSpeedSequence {
    [self stopAndResetSpeed];

    __block NSInteger elapsedSeconds = 0;
    
    dispatch_queue_t queue = dispatch_get_main_queue();
    autoSpeedTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    
    dispatch_source_set_timer(autoSpeedTimer,
                              dispatch_time(DISPATCH_TIME_NOW, 1LL * NSEC_PER_SEC),
                              1LL * NSEC_PER_SEC,
                              0);

    dispatch_source_set_event_handler(autoSpeedTimer, ^{
        elapsedSeconds++;
        
        // Đếm tới giây thứ 4 -> Kích hoạt x5
        if (elapsedSeconds == 4) {
            set_speed_factor(5.0f);
        }
        // Đếm tới giây thứ 7 -> Tắt x5, trở về 1x
        else if (elapsedSeconds >= 7) {
            [OrderSpeedTrigger stopAndResetSpeed];
        }
    });

    dispatch_resume(autoSpeedTimer);
}

@end

// ==========================================
// 3. HOOK VÀO VÒNG ĐỜI MÀN HÌNH ĐƠN
// ==========================================
static void (*orig_viewDidAppear)(id self, SEL _cmd, BOOL animated);
static void (*orig_viewWillDisappear)(id self, SEL _cmd, BOOL animated);

static void my_viewDidAppear(UIViewController *self, SEL _cmd, BOOL animated) {
    orig_viewDidAppear(self, _cmd, animated);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.20 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if ([OrderSpeedTrigger isMainListScreen:self.view]) {
            [OrderSpeedTrigger stopAndResetSpeed];
            return;
        }
        [OrderSpeedTrigger startAutoSpeedSequence];
    });
}

static void my_viewWillDisappear(UIViewController *self, SEL _cmd, BOOL animated) {
    orig_viewWillDisappear(self, _cmd, animated);
    [OrderSpeedTrigger stopAndResetSpeed];
}

static void hook_ui_lifecycle(void) {
    Class vcClass = [UIViewController class];
    
    SEL appearSel = @selector(viewDidAppear:);
    Method appearMethod = class_getInstanceMethod(vcClass, appearSel);
    orig_viewDidAppear = (void (*)(id, SEL, BOOL))method_getImplementation(appearMethod);
    method_setImplementation(appearMethod, (IMP)my_viewDidAppear);

    SEL disappearSel = @selector(viewWillDisappear:);
    Method disappearMethod = class_getInstanceMethod(vcClass, disappearSel);
    orig_viewWillDisappear = (void (*)(id, SEL, BOOL))method_getImplementation(disappearMethod);
    method_setImplementation(disappearMethod, (IMP)my_viewWillDisappear);
}

// ==========================================
// 4. INITIALIZER
// ==========================================
__attribute__((constructor))
static void initialize(void) {
    struct rebinding rebindings[] = {
        {"gettimeofday", (void *)my_gettimeofday, (void **)&orig_gettimeofday},
        {"CFAbsoluteTimeGetCurrent", (void *)my_CFAbsoluteTimeGetCurrent, (void **)&orig_CFAbsoluteTimeGetCurrent},
        {"mach_absolute_time", (void *)my_mach_absolute_time, (void **)&orig_mach_absolute_time}
    };
    rebind_symbols(rebindings, 3);

    Class nsdateClass = [NSDate class];
    Method origRef = class_getClassMethod(nsdateClass, @selector(timeIntervalSinceReferenceDate));
    if (origRef) method_setImplementation(origRef, (IMP)my_CFAbsoluteTimeGetCurrent);
    
    Method origDate = class_getClassMethod(nsdateClass, @selector(date));
    if (origDate) {
        method_setImplementation(origDate, imp_implementationWithBlock(^id(id self) {
            return [NSDate dateWithTimeIntervalSinceReferenceDate:my_CFAbsoluteTimeGetCurrent()];
        }));
    }

    hook_ui_lifecycle();
}
