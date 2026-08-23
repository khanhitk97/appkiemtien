// ==========================================
// 3. OVERLAY CHẶN THANH TRƯỢT "VUỐT ĐỂ NHẬN ĐƠN"
// ==========================================
@interface OrderOverlayManager : NSObject
+ (void)showOverlayForTimeInterval:(NSTimeInterval)seconds onViewController:(UIViewController *)vc;
@end

@implementation OrderOverlayManager

+ (void)showOverlayForTimeInterval:(NSTimeInterval)seconds onViewController:(UIViewController *)vc {
    NSInteger overlayTag = 998877;
    // Tránh tạo trùng lặp nếu màn hình đã có lớp phủ
    if ([vc.view viewWithTag:overlayTag]) {
        return;
    }

    CGFloat screenWidth = [UIScreen mainScreen].bounds.size.width;
    CGFloat screenHeight = [UIScreen mainScreen].bounds.size.height;
    
    // Tọa độ khớp với thanh trượt bo tròn trong ảnh
    CGFloat sliderWidth = screenWidth - 60.0f; // Cách đều 2 lề 30pt
    CGFloat sliderHeight = 56.0f;              // Chiều cao thanh trượt
    CGFloat bottomMargin = 45.0f;              // Cách mép dưới màn hình (trên Home Bar)
    CGFloat sliderX = 30.0f;
    CGFloat sliderY = screenHeight - sliderHeight - bottomMargin;

    // View overlay che khít thanh trượt
    UIView *overlay = [[UIView alloc] initWithFrame:CGRectMake(sliderX, sliderY, sliderWidth, sliderHeight)];
    overlay.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.85];
    overlay.userInteractionEnabled = YES; // Chặn hoàn toàn cử chỉ vuốt
    overlay.tag = overlayTag;
    overlay.layer.cornerRadius = sliderHeight / 2.0f; // Bo tròn dạng capsule đúng form thanh trượt
    overlay.layer.borderWidth = 1.5f;
    overlay.layer.borderColor = [UIColor whiteColor].CGColor;
    overlay.clipsToBounds = YES;

    // Label đếm ngược hiển thị ở giữa thanh
    UILabel *countdownLabel = [[UILabel alloc] initWithFrame:overlay.bounds];
    countdownLabel.textColor = [UIColor whiteColor];
    countdownLabel.font = [UIFont boldSystemFontOfSize:16.0f];
    countdownLabel.textAlignment = NSTextAlignmentCenter;
    [overlay addSubview:countdownLabel];

    [vc.view addSubview:overlay];

    __block NSInteger remainingSeconds = (NSInteger)seconds;
    countdownLabel.text = [NSString stringWithFormat:@"Đọc kỹ đơn: chờ %lds...", (long)remainingSeconds];

    // Timer đếm ngược 1s/lần
    NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer * _Nonnull t) {
        remainingSeconds--;
        if (remainingSeconds > 0) {
            countdownLabel.text = [NSString stringWithFormat:@"Đọc kỹ đơn: chờ %lds...", (long)remainingSeconds];
        } else {
            [t invalidate];
            // Hiệu ứng mờ dần sau 5s để lộ thanh trượt cho phép vuốt nhận đơn
            [UIView animateWithDuration:0.25 animations:^{
                overlay.alpha = 0.0f;
                overlay.transform = CGAffineTransformMakeScale(0.95, 0.95);
            } completion:^(BOOL finished) {
                [overlay removeFromSuperview];
            }];
        }
    }];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
}

@end
