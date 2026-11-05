#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import "Engine.h"
#import "Solver.h"

static NSString *const SpeedKey = @"Auto2048.speed";
// Minimum delay after a move, in seconds, for x1 / x2 / x4 / MAX.
// The real interval is longer when the search or the tile animation takes time.
// MAX has no wait at all: the next move is considered as soon as the previous
// one is done, so the only time spent per move is the search plus the seconds
// the game itself needs to settle its tiles.
static const double Intervals[] = {0.45, 0.32, 0.22, 0.0};
static NSString *const Names[] = {@"x1", @"x2", @"x4", @"MAX"};

@interface Auto2048Controller : NSObject
@property(nonatomic, strong) CADisplayLink *link;
@property(nonatomic, strong) UIButton *button;
@property(nonatomic, strong) UIButton *retryButton;
@property(nonatomic, weak) UIWindow *attached;
@property(nonatomic) BOOL enabled;
@property(nonatomic) NSInteger speed;
@property(nonatomic) CFTimeInterval last;
@property(nonatomic, strong) NSString *status;
@property(nonatomic) BOOL pending;
@property(nonatomic) NSUInteger epoch;
// Start over as soon as a game is over. Off on launch, never persisted.
@property(nonatomic) BOOL retry;
@property(nonatomic) CFTimeInterval lastRetry;
@end

@implementation Auto2048Controller

+ (instancetype)shared {
    static Auto2048Controller *v;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        v = [self new];
    });
    return v;
}

- (instancetype)init {
    if ((self = [super init])) {
        _speed = MIN(3, MAX(0, [NSUserDefaults.standardUserDefaults integerForKey:SpeedKey]));
        _status = @"OFF";
    }
    return self;
}

- (void)start {
    if (self.link) return;
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(resign:)
                                                 name:UIApplicationWillResignActiveNotification
                                               object:nil];
    self.link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
    [self.link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

- (void)refresh {
    [self.button setTitle:[NSString stringWithFormat:@"AUTO %@\n%@", self.status, Names[self.speed]]
                 forState:UIControlStateNormal];
    self.button.backgroundColor = self.enabled ? [UIColor colorWithRed:0.12 green:0.50 blue:0.32 alpha:0.88]
                                               : [UIColor colorWithWhite:0.12 alpha:0.85];
    [self.retryButton setTitle:[NSString stringWithFormat:@"RETRY\n%@", self.retry ? @"ON" : @"OFF"]
                      forState:UIControlStateNormal];
    self.retryButton.backgroundColor = self.retry ? [UIColor colorWithRed:0.78 green:0.42 blue:0.12 alpha:0.90]
                                                  : [UIColor colorWithWhite:0.12 alpha:0.85];
}

- (UIButton *)makeButton:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:10];
    b.titleLabel.numberOfLines = 2;
    b.titleLabel.textAlignment = NSTextAlignmentCenter;
    b.layer.cornerRadius = 12;
    b.layer.borderWidth = 1;
    b.layer.borderColor = UIColor.whiteColor.CGColor;
    b.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin;
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

// Turning the retry on also starts the auto-play: a game over can only be
// noticed while the AI is playing.
- (void)tapRetry {
    self.retry = !self.retry;
    if (self.retry && !self.enabled) {
        self.enabled = YES;
        self.status = @"START";
        self.epoch++;
        self.last = CACurrentMediaTime();
    }
    [self refresh];
}

// Called when the game stopped (PAUSE) or the search found no move (END).
- (void)retryNow {
    if (!self.retry || self.pending) return;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - self.lastRetry < 2.0) return;
    self.lastRetry = now;
    if (!Auto2048GameOver()) return;
    if (![Auto2048Restart() isEqualToString:@"ON"]) return;
    self.pending = NO;
    self.enabled = YES;
    self.status = @"RETRY";
    self.epoch++;
    self.last = CACurrentMediaTime();
    [self refresh];
}

// Losing focus invalidates any search that is still running.
- (void)resign:(NSNotification *)note {
    (void)note;
    self.epoch++;
}

- (void)tap {
    self.epoch++;
    self.enabled = !self.enabled;
    self.status = self.enabled ? @"START" : @"OFF";
    self.last = CACurrentMediaTime();
    [self refresh];
}

- (void)hold:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    self.speed = (self.speed + 1) % 4;
    [NSUserDefaults.standardUserDefaults setInteger:self.speed forKey:SpeedKey];
    [self refresh];
}

// The game redraws its own windows, so find the foreground-active window each time.
- (UIWindow *)window {
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (s.activationState == UISceneActivationStateForegroundActive && [s isKindOfClass:UIWindowScene.class]) {
            UIWindowScene *ws = (UIWindowScene *)s;
            for (UIWindow *w in ws.windows)
                if (w.isKeyWindow && !w.hidden) return w;
            for (UIWindow *w in ws.windows)
                if (!w.hidden && w.windowLevel == UIWindowLevelNormal) return w;
        }
    }
    return nil;
}

- (void)attach {
    UIWindow *w = [self window];
    if (!w) return;

    if (!self.button) {
        self.button = [self makeButton:@selector(tap)];
        UILongPressGestureRecognizer *g = [[UILongPressGestureRecognizer alloc] initWithTarget:self
                                                                                       action:@selector(hold:)];
        g.minimumPressDuration = 0.55;
        g.cancelsTouchesInView = YES;
        [self.button addGestureRecognizer:g];
        self.retryButton = [self makeButton:@selector(tapRetry)];
        [self refresh];
    }

    if (self.attached != w) {
        [self.button removeFromSuperview];
        [self.retryButton removeFromSuperview];
        [w addSubview:self.button];
        [w addSubview:self.retryButton];
        self.attached = w;
        CGFloat x = MAX(4, w.bounds.size.width - 92);
        self.button.frame = CGRectMake(x, MAX(4, w.bounds.size.height - 126), 80, 56);
        self.retryButton.frame = CGRectMake(x, MAX(4, w.bounds.size.height - 190), 80, 56);
    }
}

- (void)setDisplayStatus:(NSString *)status {
    if (![status isEqualToString:self.status]) {
        self.status = status;
        [self refresh];
    }
    if ([status isEqualToString:@"END"] && self.retry) {
        [self retryNow];
        return;
    }
    if ([status isEqualToString:@"END"] || [status isEqualToString:@"ERR"] || [status isEqualToString:@"DATA"] ||
        [status isEqualToString:@"SIZE"]) {
        self.enabled = NO;
        self.epoch++;
        [self refresh];
    }
}

- (void)tick:(CADisplayLink *)link {
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    [self attach];
    if (!self.enabled || self.pending || link.timestamp - self.last < Intervals[self.speed]) return;

    self.last = link.timestamp;
    Auto2048Snapshot snapshot;
    NSString *status = Auto2048Read(&snapshot);
    if (![status isEqualToString:@"OK"]) {
        [self setDisplayStatus:status];
        if ([status isEqualToString:@"PAUSE"]) [self retryNow];
        return;
    }

    self.pending = YES;
    NSUInteger epoch = self.epoch;
    [self setDisplayStatus:@"THINK"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int direction = solver_best(snapshot.board);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.pending = NO;
            if (!self.enabled || self.epoch != epoch ||
                UIApplication.sharedApplication.applicationState != UIApplicationStateActive)
                return;
            // Re-read the live game before sending input; discard stale results.
            NSString *result = Auto2048Apply(&snapshot, direction);
            self.last = CACurrentMediaTime();
            [self setDisplayStatus:result];
        });
    });
}

@end

__attribute__((constructor)) static void Auto2048Init(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[Auto2048Controller shared] start];
    });
}
