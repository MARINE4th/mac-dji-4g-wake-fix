#import <AppKit/AppKit.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/pwr_mgt/IOPM.h>
#import <os/log.h>
#import <signal.h>

static NSString *controller;
static bool checkPending;
static NSTask *worker;
static bool lidWasClosed;
static dispatch_source_t testSignal;
static os_log_t wakeLog;

static bool lidIsClosed(io_service_t root)
{
    CFTypeRef value = IORegistryEntryCreateCFProperty(
        root, CFSTR(kAppleClamshellStateKey), kCFAllocatorDefault, 0);
    bool closed = value && CFGetTypeID(value) == CFBooleanGetTypeID() && CFBooleanGetValue(value);
    if (value)
        CFRelease(value);
    return closed;
}

static void startWorker(NSString *mode, NSString *reason)
{
    if (worker.isRunning)
        return;
    worker = [[NSTask alloc] init];
    worker.executableURL = [NSURL fileURLWithPath:controller];
    worker.arguments = @[mode, reason];
    NSError *error;
    if (![worker launchAndReturnError:&error])
        os_log_error(wakeLog, "Unable to start recovery controller: %{public}@", error.localizedDescription);
}

static void scheduleCheck(NSString *reason)
{
    if (checkPending)
        return;
    checkPending = true;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 350 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        checkPending = false;
        startWorker(@"wake", reason);
    });
}

static void clamshellChanged(void *context, io_service_t root, natural_t message, void *argument)
{
    (void)context;
    (void)argument;
    if (message != kIOPMMessageClamshellStateChange)
        return;
    bool closed = lidIsClosed(root);
    if (lidWasClosed && !closed)
        scheduleCheck(@"开盖");
    lidWasClosed = closed;
}

int main(int argc, const char **argv)
{
    @autoreleasepool {
        if (argc != 2)
            return 2;
        wakeLog = os_log_create("local.dji4g.wake", "listener");
        controller = [NSString stringWithUTF8String:argv[1]];
        NSNotificationCenter *center = NSWorkspace.sharedWorkspace.notificationCenter;
        [center addObserverForName:NSWorkspaceDidWakeNotification object:nil
                             queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            (void)note;
            scheduleCheck(@"系统唤醒");
        }];

        IONotificationPortRef port = IONotificationPortCreate(kIOMainPortDefault);
        io_service_t root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"));
        io_object_t subscription = IO_OBJECT_NULL;
        if (port && root) {
            lidWasClosed = lidIsClosed(root);
            IOReturn result = IOServiceAddInterestNotification(
                port, root, kIOGeneralInterest, clamshellChanged, NULL, &subscription);
            if (result == kIOReturnSuccess)
                CFRunLoopAddSource(CFRunLoopGetCurrent(), IONotificationPortGetRunLoopSource(port), kCFRunLoopDefaultMode);
            else
                os_log_error(wakeLog, "Lid notification registration failed: 0x%x", result);
        }

        signal(SIGHUP, SIG_IGN);
        testSignal = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGHUP, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(testSignal, ^{ scheduleCheck(@"测试唤醒"); });
        dispatch_resume(testSignal);
        startWorker(@"resume", @"");
        os_log(wakeLog, "Listening for macOS wake and lid events");
        CFRunLoopRun();

        if (subscription)
            IOObjectRelease(subscription);
        if (root)
            IOObjectRelease(root);
        if (port)
            IONotificationPortDestroy(port);
    }
    return 0;
}
