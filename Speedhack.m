#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <sys/time.h>
#import <mach/mach_time.h>
#import <dlfcn.h>
#import <stdlib.h>
#import <string.h>
#import <sys/types.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>

#ifndef LC_SEGMENT_ARCH_DEPENDENT
#ifdef __LP64__
#define LC_SEGMENT_ARCH_DEPENDENT LC_SEGMENT_64
#else
#define LC_SEGMENT_ARCH_DEPENDENT LC_SEGMENT
#endif
#endif

// ==========================================
// 1. EMBEDDED FISHHOOK IMPLEMENTATION
// ==========================================
#ifdef __LP64__
typedef struct mach_header_64 mach_header_t;
typedef struct segment_command_64 segment_command_t;
typedef struct load_command load_command_t;
typedef struct section_64 section_t;
typedef struct nlist_64 nlist_t;
#else
typedef struct mach_header mach_header_t;
typedef struct segment_command segment_command_t;
typedef struct load_command load_command_t;
typedef struct section section_t;
typedef struct nlist nlist_t;
#endif

#ifndef SEG_DATA_CONST
#define SEG_DATA_CONST "__DATA_CONST"
#endif

struct rebinding {
  const char *name;
  void *replacement;
  void **replaced;
};

struct rebindings_entry {
  struct rebinding *rebindings;
  size_t rebindings_nel;
  struct rebindings_entry *next;
};

static struct rebindings_entry *_rebindings_head = NULL;

static int perform_rebinding_with_section(struct rebindings_entry *rebindings,
                                          section_t *section,
                                          intptr_t slide,
                                          nlist_t *symtab,
                                          char *strtab,
                                          uint32_t *indirect_symtab) {
  uint32_t *indirect_symbol_indices = indirect_symtab + section->reserved1;
  void **indirect_symbol_bindings = (void **)((uintptr_t)slide + section->addr);
  for (uint32_t i = 0; i < section->size / sizeof(void *); i++) {
    uint32_t symtab_index = indirect_symbol_indices[i];
    if (symtab_index == INDIRECT_SYMBOL_ABS || symtab_index == INDIRECT_SYMBOL_LOCAL ||
        symtab_index == (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS)) {
      continue;
    }
    uint32_t strtab_offset = symtab[symtab_index].n_un.n_strx;
    char *symbol_name = strtab + strtab_offset;
    bool symbol_has_leading_underscore = symbol_name[0] == '_';
    struct rebindings_entry *cur = rebindings;
    while (cur) {
      for (uint32_t j = 0; j < cur->rebindings_nel; j++) {
        uint32_t symbol_name_offset = symbol_has_leading_underscore ? 1 : 0;
        if (strcmp(&symbol_name[symbol_name_offset], cur->rebindings[j].name) == 0) {
          if (cur->rebindings[j].replaced != NULL &&
              indirect_symbol_bindings[i] != cur->rebindings[j].replacement) {
            *(cur->rebindings[j].replaced) = indirect_symbol_bindings[i];
          }
          indirect_symbol_bindings[i] = cur->rebindings[j].replacement;
          goto symbol_loop;
        }
      }
      cur = cur->next;
    }
  symbol_loop:;
  }
  return 0;
}

static void rebind_symbols_for_image(struct rebindings_entry *rebindings,
                                     const struct mach_header *header,
                                     intptr_t slide) {
  Dl_info info;
  if (dladdr(header, &info) == 0) return;

  segment_command_t *cur_seg_cmd;
  segment_command_t *linkedit_segment = NULL;
  struct symtab_command* symtab_cmd = NULL;
  struct dysymtab_command* dysymtab_cmd = NULL;

  uintptr_t cur = (uintptr_t)header + sizeof(mach_header_t);
  for (uint32_t i = 0; i < header->ncmds; i++, cur += cur_seg_cmd->cmdsize) {
    cur_seg_cmd = (segment_command_t *)cur;
    if (cur_seg_cmd->cmd == LC_SEGMENT_ARCH_DEPENDENT) {
      if (strcmp(cur_seg_cmd->segname, SEG_LINKEDIT) == 0) {
        linkedit_segment = cur_seg_cmd;
      }
    } else if (cur_seg_cmd->cmd == LC_SYMTAB) {
      symtab_cmd = (struct symtab_command*)cur_seg_cmd;
    } else if (cur_seg_cmd->cmd == LC_DYSYMTAB) {
      dysymtab_cmd = (struct dysymtab_command*)cur_seg_cmd;
    }
  }

  if (!symtab_cmd || !dysymtab_cmd || !linkedit_segment) return;

  uintptr_t linkedit_base = (uintptr_t)slide + linkedit_segment->vmaddr - linkedit_segment->fileoff;
  nlist_t *symtab = (nlist_t *)(linkedit_base + symtab_cmd->symoff);
  char *strtab = (char *)(linkedit_base + symtab_cmd->stroff);
  uint32_t *indirect_symtab = (uint32_t *)(linkedit_base + dysymtab_cmd->indirectsymoff);

  cur = (uintptr_t)header + sizeof(mach_header_t);
  for (uint32_t i = 0; i < header->ncmds; i++, cur += cur_seg_cmd->cmdsize) {
    cur_seg_cmd = (segment_command_t *)cur;
    if (cur_seg_cmd->cmd == LC_SEGMENT_ARCH_DEPENDENT) {
      if (strcmp(cur_seg_cmd->segname, SEG_DATA) != 0 &&
          strcmp(cur_seg_cmd->segname, SEG_DATA_CONST) != 0) {
        continue;
      }
      for (uint32_t j = 0; j < cur_seg_cmd->nsects; j++) {
        section_t *sect = (section_t *)(cur + sizeof(segment_command_t)) + j;
        if ((sect->flags & SECTION_TYPE) == S_LAZY_SYMBOL_POINTERS ||
            (sect->flags & SECTION_TYPE) == S_NON_LAZY_SYMBOL_POINTERS) {
          perform_rebinding_with_section(rebindings, sect, slide, symtab, strtab, indirect_symtab);
        }
      }
    }
  }
}

static void _rebind_symbols_for_image(const struct mach_header *header, intptr_t slide) {
    rebind_symbols_for_image(_rebindings_head, header, slide);
}

static int rebind_symbols(struct rebinding rebindings[], size_t rebindings_nel) {
  struct rebindings_entry *new_entry = (struct rebindings_entry *)malloc(sizeof(struct rebindings_entry));
  if (!new_entry) return -1;
  new_entry->rebindings = (struct rebinding *)malloc(sizeof(struct rebinding) * rebindings_nel);
  if (!new_entry->rebindings) {
    free(new_entry);
    return -1;
  }
  memcpy(new_entry->rebindings, rebindings, sizeof(struct rebinding) * rebindings_nel);
  new_entry->rebindings_nel = rebindings_nel;
  new_entry->next = _rebindings_head;
  _rebindings_head = new_entry;
  
  if (!_rebindings_head->next) {
    _dyld_register_func_for_add_image(_rebind_symbols_for_image);
  } else {
    uint32_t c = _dyld_image_count();
    for (uint32_t i = 0; i < c; i++) {
      rebind_symbols_for_image(new_entry, _dyld_get_image_header(i), _dyld_get_image_vmaddr_slide(i));
    }
  }
  return 0;
}

// ==========================================
// 2. CORE SPEED ENGINE
// ==========================================
static float speed_factor = 5.0f;

static int (*orig_gettimeofday)(struct timeval *tv, struct timezone *tz);
static CFAbsoluteTime (*orig_CFAbsoluteTimeGetCurrent)(void);
static uint64_t (*orig_mach_absolute_time)(void);

static struct timeval last_real_tv;
static struct timeval fake_tv;
static CFAbsoluteTime last_real_cf = 0;
static CFAbsoluteTime fake_cf = 0;
static uint64_t last_real_mach = 0;
static uint64_t fake_mach = 0;

int my_gettimeofday(struct timeval *tv, struct timezone *tz) {
    int ret = orig_gettimeofday(tv, tz);
    if (ret != 0 || tv == NULL) return ret;

    if (last_real_tv.tv_sec == 0) {
        last_real_tv = *tv;
        fake_tv = *tv;
    } else {
        double delta = (tv->tv_sec - last_real_tv.tv_sec) + 
                       (tv->tv_usec - last_real_tv.tv_usec) / 1000000.0;
        double fake_delta = delta * speed_factor;
        
        long sec_add = (long)fake_delta;
        long usec_add = (long)((fake_delta - sec_add) * 1000000.0);
        
        fake_tv.tv_sec += sec_add;
        fake_tv.tv_usec += usec_add;
        if (fake_tv.tv_usec >= 1000000) {
            fake_tv.tv_sec += 1;
            fake_tv.tv_usec -= 1000000;
        }
        last_real_tv = *tv;
    }

    *tv = fake_tv;
    return ret;
}

CFAbsoluteTime my_CFAbsoluteTimeGetCurrent(void) {
    CFAbsoluteTime real_now = orig_CFAbsoluteTimeGetCurrent();
    if (last_real_cf == 0) {
        last_real_cf = real_now;
        fake_cf = real_now;
    } else {
        double delta = real_now - last_real_cf;
        fake_cf += delta * speed_factor;
        last_real_cf = real_now;
    }
    return fake_cf;
}

uint64_t my_mach_absolute_time(void) {
    uint64_t real_now = orig_mach_absolute_time();
    if (last_real_mach == 0) {
        last_real_mach = real_now;
        fake_mach = real_now;
    } else {
        uint64_t delta = real_now - last_real_mach;
        fake_mach += (uint64_t)(delta * speed_factor);
        last_real_mach = real_now;
    }
    return fake_mach;
}

static void swizzle_NSDate_methods(void) {
    Class nsdateClass = [NSDate class];
    Method origRefMethod = class_getClassMethod(nsdateClass, @selector(timeIntervalSinceReferenceDate));
    if (origRefMethod) {
        method_setImplementation(origRefMethod, (IMP)my_CFAbsoluteTimeGetCurrent);
    }
    
    Method origDateMethod = class_getClassMethod(nsdateClass, @selector(date));
    if (origDateMethod) {
        IMP newDateImp = imp_implementationWithBlock(^id(id self) {
            return [NSDate dateWithTimeIntervalSinceReferenceDate:my_CFAbsoluteTimeGetCurrent()];
        });
        method_setImplementation(origDateMethod, newDateImp);
    }
}

// ==========================================
// 3. EXACT RCTView OVERLAY MANAGER
// ==========================================
static const NSInteger kOrderOverlayTag = 998877;
static NSTimer *activeCountdownTimer = nil;
static UIView *currentOverlayView = nil;

@interface OrderOverlayManager : NSObject
+ (void)showOverlayForTimeInterval:(NSTimeInterval)seconds onViewController:(UIViewController *)vc;
+ (void)cancelOverlayImmediately;
+ (BOOL)isMainListScreen:(UIView *)view;
+ (UIView *)findRCTSwipeButtonView:(UIView *)view;
@end

@implementation OrderOverlayManager

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

+ (UIView *)findRCTSwipeButtonView:(UIView *)view {
    CGFloat w = view.frame.size.width;
    CGFloat h = view.frame.size.height;

    // Khớp kích thước RCTView từ inspector (width ~240-275pt, height ~45-55pt)
    if (w >= 240.0f && w <= 275.0f && h >= 45.0f && h <= 55.0f) {
        return view;
    }

    for (UIView *subview in view.subviews) {
        UIView *found = [self findRCTSwipeButtonView:subview];
        if (found) return found;
    }
    return nil;
}

+ (void)cancelOverlayImmediately {
    if (activeCountdownTimer) {
        [activeCountdownTimer invalidate];
        activeCountdownTimer = nil;
    }
    if (currentOverlayView) {
        [currentOverlayView removeFromSuperview];
        currentOverlayView = nil;
    }
}

+ (void)showOverlayForTimeInterval:(NSTimeInterval)seconds onViewController:(UIViewController *)vc {
    [self cancelOverlayImmediately];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if ([self isMainListScreen:vc.view]) {
            return;
        }

        UIView *rctButton = [self findRCTSwipeButtonView:vc.view];
        
        UIView *parentView = nil;
        CGRect overlayFrame;
        CGFloat cornerRadius = 25.0f;

        if (rctButton) {
            parentView = rctButton;
            overlayFrame = rctButton.bounds;
        } else {
            CGFloat screenWidth = [UIScreen mainScreen].bounds.size.width;
            CGFloat screenHeight = [UIScreen mainScreen].bounds.size.height;
            CGFloat btnWidth = 256.66f;
            CGFloat btnHeight = 50.0f;
            CGFloat bottomSpacing = 55.0f;
            
            parentView = vc.view;
            overlayFrame = CGRectMake((screenWidth - btnWidth) / 2.0f, screenHeight - btnHeight - bottomSpacing, btnWidth, btnHeight);
        }

        UIView *overlay = [[UIView alloc] initWithFrame:overlayFrame];
        overlay.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.92];
        overlay.userInteractionEnabled = YES;
        overlay.tag = kOrderOverlayTag;
        overlay.layer.cornerRadius = cornerRadius;
        overlay.clipsToBounds = YES;
        overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

        UILabel *countdownLabel = [[UILabel alloc] initWithFrame:overlay.bounds];
        countdownLabel.textColor = [UIColor whiteColor];
        countdownLabel.font = [UIFont boldSystemFontOfSize:15.0f];
        countdownLabel.textAlignment = NSTextAlignmentCenter;
        countdownLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [overlay addSubview:countdownLabel];

        [parentView addSubview:overlay];
        [parentView bringSubviewToFront:overlay];
        currentOverlayView = overlay;

        __block NSInteger remainingSeconds = (NSInteger)seconds;
        countdownLabel.text = [NSString stringWithFormat:@"Đọc kỹ đơn: chờ %lds...", (long)remainingSeconds];

        activeCountdownTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer * _Nonnull t) {
            remainingSeconds--;
            if (remainingSeconds > 0) {
                countdownLabel.text = [NSString stringWithFormat:@"Đọc kỹ đơn: chờ %lds...", (long)remainingSeconds];
            } else {
                [t invalidate];
                activeCountdownTimer = nil;
                [UIView animateWithDuration:0.25 animations:^{
                    if (currentOverlayView) {
                        currentOverlayView.alpha = 0.0f;
                    }
                } completion:^(BOOL finished) {
                    [OrderOverlayManager cancelOverlayImmediately];
                }];
            }
        }];
        [[NSRunLoop mainRunLoop] addTimer:activeCountdownTimer forMode:NSRunLoopCommonModes];
    });
}

@end

// ==========================================
// 4. HOOK VIEW CONTROLLER LIFECYCLE
// ==========================================
static void (*orig_viewDidAppear)(id self, SEL _cmd, BOOL animated);
static void (*orig_viewWillDisappear)(id self, SEL _cmd, BOOL animated);

static void my_viewDidAppear(UIViewController *self, SEL _cmd, BOOL animated) {
    orig_viewDidAppear(self, _cmd, animated);
    [OrderOverlayManager showOverlayForTimeInterval:5.0 onViewController:self];
}

static void my_viewWillDisappear(UIViewController *self, SEL _cmd, BOOL animated) {
    orig_viewWillDisappear(self, _cmd, animated);
    [OrderOverlayManager cancelOverlayImmediately];
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
// 5. INITIALIZER
// ==========================================
__attribute__((constructor))
static void initialize(void) {
    struct rebinding rebindings[] = {
        {"gettimeofday", (void *)my_gettimeofday, (void **)&orig_gettimeofday},
        {"CFAbsoluteTimeGetCurrent", (void *)my_CFAbsoluteTimeGetCurrent, (void **)&orig_CFAbsoluteTimeGetCurrent},
        {"mach_absolute_time", (void *)my_mach_absolute_time, (void **)&orig_mach_absolute_time}
    };
    rebind_symbols(rebindings, 3);
    swizzle_NSDate_methods();
    hook_ui_lifecycle();
}
