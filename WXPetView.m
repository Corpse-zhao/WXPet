#import "WXPetView.h"
#import "WXPCommon.h"
#import <math.h>

// ═══════════════════════════════════════════════════════════════════════════
//  宠物外观：**程序化绘制**（零素材依赖）
//
//  为什么不用图片素材：
//    ① 版权干净 —— 不带任何第三方美术资源；
//    ② 装完就有东西看 —— 不会出现「装上了但一片空白」这种最难排查的状态；
//    ③ 矢量绘制，任何尺寸都清晰（宠物大小是可调的）。
//
//  想换成自己的宠物：在共享目录放精灵帧即可（见 loadSpritesIfAny）
//    /var/mobile/Documents/悬浮宠物/pet/idle_1.png, idle_2.png, ...
//    放满 2 张以上就自动切换成你的图，程序化绘制自动让位。
// ═══════════════════════════════════════════════════════════════════════════

// 四角星（撒花用）：画在 (0,0,2r,2r) 的方框里，中心在 (r,r)
static UIBezierPath *WXPSparkPath(CGFloat r) {
    CGFloat c = r;
    CGFloat k = r * 0.20;   // 内凹控制量，越小越尖
    UIBezierPath *p = [UIBezierPath bezierPath];
    [p moveToPoint:CGPointMake(c, c - r)];
    [p addQuadCurveToPoint:CGPointMake(c + r, c) controlPoint:CGPointMake(c + k, c - k)];
    [p addQuadCurveToPoint:CGPointMake(c, c + r) controlPoint:CGPointMake(c + k, c + k)];
    [p addQuadCurveToPoint:CGPointMake(c - r, c) controlPoint:CGPointMake(c - k, c + k)];
    [p addQuadCurveToPoint:CGPointMake(c, c - r) controlPoint:CGPointMake(c - k, c - k)];
    [p closePath];
    return p;
}

#pragma mark - 宠物本体（只负责「长什么样 / 会呼吸眨眼」，不处理手势）

@interface WXPBodyView : UIView
@property (nonatomic, strong) UIColor *bodyColor;
@property (nonatomic, strong) UIColor *inkColor;
- (void)blinkNow;
- (void)startIdleAnimations;
@end

@implementation WXPBodyView {
    CAShapeLayer *_leftEye;
    CAShapeLayer *_rightEye;
    CAShapeLayer *_leftGlint;
    CAShapeLayer *_rightGlint;
    BOOL _useSprite;
    UIImageView *_spriteView;
    BOOL _blinkScheduled;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;
        self.userInteractionEnabled = NO;               // 手势统一交给外层
        self.contentMode = UIViewContentModeRedraw;     // 尺寸变了要重绘
        self.bodyColor = [UIColor colorWithRed:1.00 green:0.71 blue:0.48 alpha:1.0];
        self.inkColor  = [UIColor colorWithRed:0.24 green:0.16 blue:0.13 alpha:1.0];

        _leftEye    = [CAShapeLayer layer];
        _rightEye   = [CAShapeLayer layer];
        _leftGlint  = [CAShapeLayer layer];
        _rightGlint = [CAShapeLayer layer];
        for (CAShapeLayer *l in @[_leftEye, _rightEye]) {
            l.fillColor = self.inkColor.CGColor;
            [self.layer addSublayer:l];
        }
        for (CAShapeLayer *l in @[_leftGlint, _rightGlint]) {
            l.fillColor = [UIColor colorWithWhite:1.0 alpha:0.92].CGColor;
            [self.layer addSublayer:l];
        }

        [self loadSpritesIfAny];
        [self startIdleAnimations];
    }
    return self;
}

// 有精灵帧就用精灵帧，没有就用程序化绘制（fail-open：永远有东西可看）
- (void)loadSpritesIfAny {
    NSString *dir = [WXPSharedDir() stringByAppendingPathComponent:@"pet"];
    NSMutableArray<UIImage *> *imgs = [NSMutableArray array];
    for (NSInteger i = 1; i <= 32; i++) {
        NSString *p = [dir stringByAppendingPathComponent:
                       [NSString stringWithFormat:@"idle_%ld.png", (long)i]];
        UIImage *im = [UIImage imageWithContentsOfFile:p];
        if (!im) break;
        [imgs addObject:im];
    }
    if (imgs.count < 2) return;

    _useSprite = YES;
    for (CAShapeLayer *l in @[_leftEye, _rightEye, _leftGlint, _rightGlint]) l.hidden = YES;

    _spriteView = [[UIImageView alloc] initWithFrame:self.bounds];
    _spriteView.contentMode = UIViewContentModeScaleAspectFit;
    _spriteView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _spriteView.animationImages = imgs;
    _spriteView.animationDuration = MAX(0.6, 0.12 * (double)imgs.count);
    _spriteView.animationRepeatCount = 0;
    [self addSubview:_spriteView];
    [_spriteView startAnimating];
    [self setNeedsDisplay];

    WXPProbeLog(@"[宠物] 使用自定义精灵帧 %lu 张（%@）", (unsigned long)imgs.count, dir);
}

- (void)startIdleAnimations {
    if (_useSprite) return;
    [self.layer removeAllAnimations];

    // 呼吸：纵向轻微缩放
    CABasicAnimation *breathe = [CABasicAnimation animationWithKeyPath:@"transform.scale.y"];
    breathe.fromValue = @1.0;
    breathe.toValue   = @0.955;
    breathe.duration  = 1.75;
    breathe.autoreverses = YES;
    breathe.repeatCount  = HUGE_VALF;
    breathe.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [self.layer addAnimation:breathe forKey:@"breathe"];

    // 上下浮动
    CABasicAnimation *bob = [CABasicAnimation animationWithKeyPath:@"transform.translation.y"];
    bob.fromValue = @0.0;
    bob.toValue   = @(-3.0);
    bob.duration  = 1.75;
    bob.autoreverses = YES;
    bob.repeatCount  = HUGE_VALF;
    bob.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [self.layer addAnimation:bob forKey:@"bob"];

    [self scheduleBlink];
}

- (void)scheduleBlink {
    if (_useSprite || _blinkScheduled) return;
    _blinkScheduled = YES;
    __weak typeof(self) weakSelf = self;
    double delay = 2.0 + (double)arc4random_uniform(320) / 100.0;   // 2.0 ~ 5.2s
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        WXPBodyView *me = weakSelf;
        if (!me) return;
        me->_blinkScheduled = NO;
        [me blinkNow];
        [me scheduleBlink];
    });
}

- (void)blinkNow {
    if (_useSprite) return;
    for (CAShapeLayer *l in @[_leftEye, _rightEye]) {
        CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"transform.scale.y"];
        a.fromValue = @1.0;
        a.toValue   = @0.10;
        a.duration  = 0.075;
        a.autoreverses = YES;
        a.repeatCount  = 1;
        a.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [l addAnimation:a forKey:@"blink"];
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    if (_useSprite) return;

    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    if (w < 4.0 || h < 4.0) return;

    CGFloat eyeW = w * 0.125;
    CGFloat eyeH = h * 0.150;
    CGFloat eyeY = h * 0.505;
    CGFloat eyeLX = w * 0.365;
    CGFloat eyeRX = w * 0.635;
    CGFloat glintR = eyeW * 0.27;

    // CAShapeLayer 的 anchorPoint 默认 (0.5,0.5)，眨眼就是绕中心纵向压扁
    for (CAShapeLayer *l in @[_leftEye, _rightEye]) {
        l.bounds = CGRectMake(0, 0, eyeW, eyeH);
    }
    _leftEye.position  = CGPointMake(eyeLX, eyeY);
    _rightEye.position = CGPointMake(eyeRX, eyeY);
    _leftEye.path  = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(0, 0, eyeW, eyeH)].CGPath;
    _rightEye.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(0, 0, eyeW, eyeH)].CGPath;

    for (CAShapeLayer *l in @[_leftGlint, _rightGlint]) {
        l.bounds = CGRectMake(0, 0, glintR * 2.0, glintR * 2.0);
        l.path = [UIBezierPath bezierPathWithOvalInRect:
                  CGRectMake(0, 0, glintR * 2.0, glintR * 2.0)].CGPath;
    }
    _leftGlint.position  = CGPointMake(eyeLX - eyeW * 0.24, eyeY - eyeH * 0.26);
    _rightGlint.position = CGPointMake(eyeRX - eyeW * 0.24, eyeY - eyeH * 0.26);
}

- (void)drawRect:(CGRect)rect {
    if (_useSprite) return;

    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    if (w < 4.0 || h < 4.0) return;

    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;
    CGContextSetShouldAntialias(ctx, YES);

    // ── 耳朵（先画，让身体盖住下半部分，形成「长在头上」的效果）
    CGFloat earR = w * 0.135;
    CGFloat earY = h * 0.205;
    [self.bodyColor setFill];
    for (NSNumber *nx in @[@0.245, @0.755]) {
        CGFloat cx = w * (CGFloat)[nx doubleValue];
        UIBezierPath *ear = [UIBezierPath bezierPathWithOvalInRect:
                             CGRectMake(cx - earR, earY - earR, earR * 2.0, earR * 2.0)];
        [ear fill];
    }

    // ── 身体：大圆角方块 = 团子形
    CGRect bodyRect = CGRectInset(self.bounds, w * 0.055, h * 0.10);
    CGFloat radius = MIN(bodyRect.size.width, bodyRect.size.height) * 0.455;
    UIBezierPath *body = [UIBezierPath bezierPathWithRoundedRect:bodyRect
                                                    cornerRadius:radius];
    [self.bodyColor setFill];
    [body fill];

    // ── 腮红
    UIColor *blush = [UIColor colorWithRed:1.00 green:0.58 blue:0.60 alpha:0.50];
    [blush setFill];
    CGFloat blushW = w * 0.165;
    CGFloat blushH = h * 0.095;
    for (NSNumber *nx in @[@0.235, @0.765]) {
        CGFloat cx = w * (CGFloat)[nx doubleValue];
        CGFloat cy = h * 0.635;
        UIBezierPath *b = [UIBezierPath bezierPathWithOvalInRect:
                           CGRectMake(cx - blushW / 2.0, cy - blushH / 2.0, blushW, blushH)];
        [b fill];
    }

    // ── 嘴：一小段微笑弧
    UIBezierPath *mouth = [UIBezierPath bezierPathWithArcCenter:CGPointMake(w * 0.50, h * 0.585)
                                                        radius:w * 0.082
                                                    startAngle:M_PI * 0.16
                                                      endAngle:M_PI * 0.84
                                                     clockwise:YES];
    mouth.lineWidth = MAX(1.5, w * 0.036);
    mouth.lineCapStyle = kCGLineCapRound;
    [self.inkColor setStroke];
    [mouth stroke];
}

@end

#pragma mark - 可交互的宠物视图

@interface WXPetView ()
@property (nonatomic, strong) WXPBodyView *body;
@property (nonatomic, assign) BOOL dimmed;
@end

@implementation WXPetView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;
        self.userInteractionEnabled = YES;
        self.draggable = YES;
        self.snapEdge  = YES;

        _body = [[WXPBodyView alloc] initWithFrame:self.bounds];
        _body.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:_body];

        UIPanGestureRecognizer *pan =
            [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [self addGestureRecognizer:pan];

        UITapGestureRecognizer *doubleTap =
            [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleDoubleTap:)];
        doubleTap.numberOfTapsRequired = 2;
        [self addGestureRecognizer:doubleTap];

        UITapGestureRecognizer *singleTap =
            [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleSingleTap:)];
        [singleTap requireGestureRecognizerToFail:doubleTap];   // 双击时不触发单击
        [self addGestureRecognizer:singleTap];

        UILongPressGestureRecognizer *longPress =
            [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
        longPress.minimumPressDuration = 0.9;
        [self addGestureRecognizer:longPress];
    }
    return self;
}

#pragma mark - 拖动

// 拖动范围限制在宿主视图内，并留出安全边距（顶部避开状态栏/刘海）
- (void)handlePan:(UIPanGestureRecognizer *)g {
    UIView *host = self.superview;
    if (!host) return;

    CGPoint t = [g translationInView:host];
    [g setTranslation:CGPointZero inView:host];

    if (self.draggable && (g.state == UIGestureRecognizerStateBegan ||
                           g.state == UIGestureRecognizerStateChanged)) {
        CGPoint c = self.center;
        c.x += t.x;
        c.y += t.y;

        CGFloat hw = self.bounds.size.width / 2.0;
        CGFloat hh = self.bounds.size.height / 2.0;
        CGRect b = host.bounds;
        CGFloat minX = hw + 2.0,                 maxX = b.size.width - hw - 2.0;
        CGFloat minY = hh + 34.0,                maxY = b.size.height - hh - 6.0;
        if (maxX < minX) maxX = minX;
        if (maxY < minY) maxY = minY;
        c.x = MAX(minX, MIN(maxX, c.x));
        c.y = MAX(minY, MIN(maxY, c.y));
        self.center = c;

        CGFloat vx = [g velocityInView:host].x;
        CGFloat ang = MAX(-0.30, MIN(0.30, vx / 4200.0));
        self.transform = CGAffineTransformMakeRotation(ang);
    }

    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        [UIView animateWithDuration:0.40 delay:0
             usingSpringWithDamping:0.55 initialSpringVelocity:0.0
                            options:UIViewAnimationOptionAllowUserInteraction |
                                    UIViewAnimationOptionBeginFromCurrentState
                         animations:^{ self.transform = CGAffineTransformIdentity; }
                         completion:nil];
        if (self.snapEdge) {
            [self snapToEdgeAnimated:YES];   // 完成时会回调 delegate 存位置
        } else {
            [self notifyDragFinished];
        }
    }
}

- (void)handleSingleTap:(UITapGestureRecognizer *)g {
    (void)g;
    [self celebration];
}

- (void)handleDoubleTap:(UITapGestureRecognizer *)g {
    (void)g;
    [self snapToEdgeAnimated:YES];
}

// 长按：在半透明「休息模式」之间切换 —— 看视频/玩游戏时不挡视线，再长按恢复
- (void)handleLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    self.dimmed = !self.dimmed;
    CGFloat a = self.dimmed ? 0.32 : 1.0;
    WXPBodyView *b = self.body;
    [UIView animateWithDuration:0.20 animations:^{ b.alpha = a; }];
}

#pragma mark - 动作

- (void)celebration {
    [self jump];
    [self spawnSparkles];
    [self.body blinkNow];
}

- (void)jump {
    WXPBodyView *b = self.body;
    if (!b) return;
    [UIView animateWithDuration:0.14 delay:0
                        options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionAllowUserInteraction
                     animations:^{ b.transform = CGAffineTransformMakeTranslation(0, -16); }
                     completion:^(BOOL finished) {
        (void)finished;
        [UIView animateWithDuration:0.42 delay:0
             usingSpringWithDamping:0.42 initialSpringVelocity:0.8
                            options:UIViewAnimationOptionAllowUserInteraction
                         animations:^{ b.transform = CGAffineTransformIdentity; }
                         completion:nil];
    }];
}

- (void)spawnSparkles {
    CGSize sz = self.bounds.size;
    if (sz.width < 8.0) return;
    CGFloat baseR = MAX(3.0, sz.width * 0.055);

    for (NSInteger i = 0; i < 3; i++) {
        CGFloat r = baseR * (1.0 - 0.18 * (CGFloat)i);
        CAShapeLayer *l = [CAShapeLayer layer];
        l.path = WXPSparkPath(r).CGPath;
        l.fillColor = [UIColor colorWithWhite:1.0 alpha:0.96].CGColor;
        l.opacity = 1.0;

        CGFloat startX = sz.width * (0.24 + 0.26 * (CGFloat)i);
        CGFloat startY = sz.height * (0.34 + 0.06 * (CGFloat)(i % 2));
        l.frame = CGRectMake(startX - r, startY - r, r * 2.0, r * 2.0);
        [self.layer addSublayer:l];

        CFTimeInterval dur = 0.85 + 0.12 * (double)i;

        CABasicAnimation *rise = [CABasicAnimation animationWithKeyPath:@"position.y"];
        rise.fromValue = @(startY);
        rise.toValue   = @(startY - sz.height * 0.42);
        rise.duration  = dur;
        rise.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];

        CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
        fade.fromValue = @1.0;
        fade.toValue   = @0.0;
        fade.duration  = dur;

        CABasicAnimation *grow = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
        grow.fromValue = @0.35;
        grow.toValue   = @1.0;
        grow.duration  = dur * 0.5;

        [l addAnimation:rise forKey:@"rise"];
        [l addAnimation:fade forKey:@"fade"];
        [l addAnimation:grow forKey:@"grow"];

        __weak CAShapeLayer *weakLayer = l;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((dur + 0.45) * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [weakLayer removeFromSuperlayer];
        });
    }
}

- (void)snapToEdgeAnimated:(BOOL)animated {
    UIView *host = self.superview;
    if (!host) return;

    CGFloat hw = self.bounds.size.width / 2.0;
    CGFloat inset = 4.0;
    CGFloat leftX  = hw + inset;
    CGFloat rightX = host.bounds.size.width - hw - inset;
    if (rightX < leftX) return;

    CGFloat x = (self.center.x < host.bounds.size.width / 2.0) ? leftX : rightX;
    if (fabs(self.center.x - x) < 0.5) {
        [self notifyDragFinished];
        return;
    }
    CGPoint target = CGPointMake(x, self.center.y);
    if (!animated) {
        self.center = target;
        [self notifyDragFinished];
        return;
    }
    __weak typeof(self) weakSelf = self;
    [UIView animateWithDuration:0.30 delay:0
         usingSpringWithDamping:0.78 initialSpringVelocity:0.4
                        options:UIViewAnimationOptionAllowUserInteraction |
                                UIViewAnimationOptionBeginFromCurrentState
                     animations:^{ weakSelf.center = target; }
                     completion:^(BOOL finished) {
        (void)finished;
        [weakSelf notifyDragFinished];
    }];
}

- (void)notifyDragFinished {
    id<WXPetViewDelegate> d = self.delegate;
    if (d && [d respondsToSelector:@selector(petViewDidFinishDrag:)]) {
        [d petViewDidFinishDrag:self];
    }
}

@end
